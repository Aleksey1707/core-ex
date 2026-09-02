# Клиент rabbitmq stream объявлен в библиотеке `optional: true`: адаптер компилируется только
# у тех потребителей, которые добавили клиента себе в `deps`. Без него модуля
# просто нет — вместо ошибки компиляции библиотеки вызов даст UndefinedFunctionError.
if Code.ensure_loaded?(RabbitMQStream.OsirisChunk) do
  defmodule Core.Mq.Stream.Reader do
    @moduledoc """
    `Mq.ReaderReliable` для RabbitMQ Stream.

    Несколько reader’ов с разными `subscriber_name` читают один stream независимо
    через `store_offset` / `query_offset` (offset_reference = subscriber_name).

    Credit — число in-flight **чанков** (не сообщений). Начальный `:credit`
    (default 2) задаёт prefetch; потолок `buffer` ≈ `credit` чанков. Credit
    возвращается, когда чанк полностью потреблён (успешный `get` или
    `decode_drop`). После `deliver` credit **не** выдаётся.

    Entries в `buffer` хранятся сырыми; `Codec.decode` — в `get`.

    Подписка устанавливается не в `init/1`, а в `handle_continue/2`: сетевые вызовы в `init`
    блокировали бы старт всего дерева супервизии (см. `.claude/rules/17-otp-concurrency.md`).
    Сбой подписки не роняет процесс — он повторяет попытку с backoff от `:retry_min_ms`
    до `:retry_max_ms`. Пока подписки нет, `get` отдаёт `:empty`: подписчики опрашивают
    reader каждые ~100 мс, и ошибка на каждом цикле залила бы лог. Недоступность видна
    по `warning` самого reader'а (их частота ограничена backoff'ом) и по `subscribed?`
    в `info/1` (уходит в метрику).

    Обязательные opts: `:connection`, `:topic`, `:subscriber_name`.
    При `reliable?: false` cursor не сохраняется (`commit` недоступен).
    """

    @behaviour Core.Mq.ReaderReliable

    use GenServer

    alias Core.Error
    alias Core.Mq
    alias Core.Mq.Codec
    alias Core.Mq.Message
    alias Core.Telemetry
    alias RabbitMQStream.Message.Types.DeliverData
    alias RabbitMQStream.OsirisChunk

    require Error
    require Logger

    @shutdown_ms 15_000
    @call_timeout 5_000
    @retry_min_ms 1_000
    @retry_max_ms 30_000

    defstruct [
      :connection,
      :topic,
      :subscriber_name,
      :subscription_id,
      :conn_ref,
      :reliable?,
      :credit,
      :initial_offset,
      :retry_min_ms,
      :retry_max_ms,
      :retry_ms,
      buffer: :queue.new(),
      chunk_remaining: 0,
      chunk_remainders: :queue.new(),
      pending: nil
    ]

    @type t :: GenServer.server()

    @doc """
    Спецификация ребёнка супервизора.

    `:shutdown` (default #{@shutdown_ms} мс) — запас на `terminate/2`: reader владеет
    подпиской в брокере и снимает её сам, иначе она висит до таймаута соединения.
    """
    @spec child_spec(keyword()) :: Supervisor.child_spec()

    def child_spec(opts) when is_list(opts) do
      %{
        id: Keyword.get(opts, :name, __MODULE__),
        start: {__MODULE__, :start_link, [opts]},
        shutdown: Keyword.get(opts, :shutdown, @shutdown_ms)
      }
    end

    @doc "Запустить reader."
    @spec start_link(keyword()) :: GenServer.on_start()

    def start_link(opts) when is_list(opts) do
      GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
    end

    @doc "Прочитать следующее сообщение."
    @spec get(t(), timeout()) :: {:ok, Message.t()} | :empty | {:error, Error.t()}

    @impl true
    def get(server, timeout \\ 0)

    def get(server, 0) do
      GenServer.call(server, :get, @call_timeout)
    end

    def get(server, timeout)
        when timeout == :infinity or (is_integer(timeout) and timeout > 0) do
      poll(server, deadline(timeout))
    end

    @doc "Зафиксировать offset текущего сообщения."
    @spec commit(t()) :: :ok | {:error, Error.t()}

    @impl true
    def commit(server) do
      GenServer.call(server, :commit, @call_timeout)
    end

    @doc "Состояние буфера reader (для метрик)."
    @spec info(t()) :: %{
            buffer_len: non_neg_integer(),
            chunk_remaining: non_neg_integer(),
            pending?: boolean(),
            subscribed?: boolean(),
            topic: String.t()
          }

    def info(server) do
      GenServer.call(server, :info, @call_timeout)
    end

    @doc false
    @impl true
    def init(opts) do
      # Подписка в брокере — внешний ресурс: без trap_exit штатная остановка
      # супервизором не вызывает terminate/2, и подписка остаётся висеть.
      Process.flag(:trap_exit, true)
      retry_min_ms = Keyword.get(opts, :retry_min_ms, @retry_min_ms)

      state = %__MODULE__{
        connection: Keyword.fetch!(opts, :connection),
        topic: Keyword.fetch!(opts, :topic),
        subscriber_name: Keyword.fetch!(opts, :subscriber_name),
        subscription_id: nil,
        conn_ref: nil,
        reliable?: Keyword.get(opts, :reliable?, true),
        credit: Keyword.get(opts, :credit, 2),
        initial_offset: Keyword.get(opts, :initial_offset, :stored),
        retry_min_ms: retry_min_ms,
        retry_max_ms: Keyword.get(opts, :retry_max_ms, @retry_max_ms),
        retry_ms: retry_min_ms
      }

      {:ok, state, {:continue, :subscribe}}
    end

    @doc false
    @impl true
    def handle_continue(:subscribe, state) do
      {:noreply, subscribe(state)}
    end

    @doc false
    @impl true
    def handle_call(:get, _from, %__MODULE__{subscription_id: nil} = state) do
      {:reply, :empty, state}
    end

    def handle_call(:get, _from, state) do
      case pop_message(state) do
        {:ok, message, state} -> {:reply, {:ok, message}, state}
        {:empty, state} -> {:reply, :empty, state}
      end
    end

    def handle_call(:info, _from, state) do
      info = %{
        buffer_len: :queue.len(state.buffer),
        chunk_remaining: state.chunk_remaining,
        pending?: not is_nil(state.pending),
        subscribed?: not is_nil(state.subscription_id),
        topic: Mq.Topic.value(state.topic)
      }

      {:reply, info, state}
    end

    def handle_call(:commit, _from, %{reliable?: false} = state) do
      {:reply,
       {:error,
        Error.app(__MODULE__,
          code: :not_reliable,
          ns: :mq,
          message: "Reader не в reliable-режиме"
        )}, state}
    end

    def handle_call(:commit, _from, %{pending: nil} = state) do
      {:reply,
       {:error,
        Error.app(__MODULE__,
          code: :nothing_to_commit,
          ns: :mq,
          message: "Нет сообщения для commit"
        )}, state}
    end

    # `store_offset` в клиенте — `GenServer.cast`: подтверждения сохранения нет, и обрыв
    # соединения виден только как exit по таймауту. Потеря offset безопасна (сообщение
    # переедет повторно), а вот падение reader'а на ней — нет.
    def handle_call(:commit, _from, %{pending: {offset, _message}} = state) do
      topic_s = Mq.Topic.value(state.topic)
      sub_s = Mq.SubscriberName.value(state.subscriber_name)

      case store_offset(state, topic_s, sub_s, offset) do
        :ok -> {:reply, :ok, %{state | pending: nil}}
        {:error, %Error{} = error} -> {:reply, {:error, error}, state}
      end
    end

    @doc false
    @impl true
    def handle_info(:resubscribe, state) do
      {:noreply, subscribe(state)}
    end

    def handle_info({:deliver, %DeliverData{osiris_chunk: %OsirisChunk{} = chunk}}, state) do
      topic = Mq.Topic.value(state.topic)

      :telemetry.execute(
        Telemetry.event([:mq, :stream, :deliver]),
        %{entries: chunk.num_entries},
        %{topic: topic}
      )

      entries = List.wrap(chunk.data_entries)

      state =
        entries
        |> Enum.with_index()
        |> Enum.reduce(state, fn {entry, idx}, acc ->
          enqueue(acc, chunk.chunk_id + idx, entry)
        end)

      {:noreply, register_chunk(state, length(entries))}
    end

    # `subscription_id` действителен только в рамках выдавшего его соединения: без этой
    # ветки после рестарта `Stream.Connection` подписка мертва навсегда, а `info/1`
    # продолжает отдавать `subscribed?: true` — алерт молчит.
    def handle_info({:DOWN, ref, :process, _pid, reason}, %__MODULE__{conn_ref: ref} = state) do
      topic_s = Mq.Topic.value(state.topic)
      sub_s = Mq.SubscriberName.value(state.subscriber_name)

      {:noreply,
       schedule_resubscribe(%{state | conn_ref: nil}, topic_s, sub_s, {:connection_down, reason})}
    end

    def handle_info(_other, state), do: {:noreply, state}

    @doc false
    @impl true
    def terminate(_reason, %{subscription_id: nil}), do: :ok

    def terminate(_reason, %{connection: conn, subscription_id: id}) do
      _ = conn.unsubscribe(id)
      :ok
    end

    def terminate(_reason, _state), do: :ok

    # ---

    defp subscribe(%__MODULE__{} = state) do
      topic_s = Mq.Topic.value(state.topic)
      sub_s = Mq.SubscriberName.value(state.subscriber_name)

      case try_subscribe(state, topic_s, sub_s) do
        {:ok, subscription_id} ->
          Logger.info("stream reader подписан: topic=#{topic_s} subscriber=#{sub_s}")

          state
          |> reset_stream_state()
          |> remonitor()
          |> Map.merge(%{subscription_id: subscription_id, retry_ms: state.retry_min_ms})

        {:error, reason} ->
          schedule_resubscribe(state, topic_s, sub_s, reason)
      end
    end

    # Буфер, счётчики чанков и `pending` принадлежат конкретной подписке: перенос их в
    # новую даёт дубли (записи придут заново от сохранённого offset) и дрейф кредитов —
    # `grant_credit` начал бы выдавать кредиты по учёту предыдущей подписки.
    defp reset_stream_state(%__MODULE__{} = state) do
      %{
        state
        | subscription_id: nil,
          buffer: :queue.new(),
          chunk_remaining: 0,
          chunk_remainders: :queue.new(),
          pending: nil
      }
    end

    defp remonitor(%__MODULE__{conn_ref: ref} = state) do
      if is_reference(ref), do: Process.demonitor(ref, [:flush])

      case GenServer.whereis(state.connection) do
        nil -> %{state | conn_ref: nil}
        pid -> %{state | conn_ref: Process.monitor(pid)}
      end
    end

    defp store_offset(state, topic_s, sub_s, offset) do
      state.connection.store_offset(topic_s, sub_s, offset)
      :ok
    catch
      :exit, reason ->
        Logger.warning(
          "stream reader: commit не доставлен topic=#{topic_s} subscriber=#{sub_s} " <>
            "reason=#{inspect(reason)}"
        )

        {:error,
         Error.app(__MODULE__,
           code: :commit_failed,
           ns: :mq,
           message: "Не удалось сохранить offset",
           detail: reason
         )}
    end

    # `connect/0` идемпотентен (открытое соединение отвечает `:ok` сразу) и обязателен для
    # `lazy: true`: такое соединение само не подключается, а буферизует запросы до таймаута.
    #
    # Недоступный брокер приходит не как `{:error, _}`, а как exit по таймауту
    # `GenServer.call` к процессу соединения — иначе ретраи бы не сработали.
    defp try_subscribe(%__MODULE__{} = state, topic_s, sub_s) do
      with :ok <- state.connection.connect(),
           :ok <- ensure_stream(state.connection, topic_s),
           offset <- resolve_offset(state.connection, topic_s, sub_s, state.initial_offset) do
        state.connection.subscribe(topic_s, self(), offset, state.credit)
      end
    catch
      :exit, reason -> {:error, {:exit, reason}}
    end

    defp schedule_resubscribe(%__MODULE__{} = state, topic_s, sub_s, reason) do
      Logger.warning(
        "stream reader: подписка не удалась topic=#{topic_s} subscriber=#{sub_s} " <>
          "reason=#{inspect(reason)} retry_in=#{state.retry_ms}ms"
      )

      Process.send_after(self(), :resubscribe, state.retry_ms)

      %{reset_stream_state(state) | retry_ms: next_retry_ms(state)}
    end

    defp next_retry_ms(%__MODULE__{retry_ms: retry_ms, retry_max_ms: max_ms}) do
      min(retry_ms * 2, max_ms)
    end

    defp enqueue(state, offset, entry) do
      %{state | buffer: :queue.in({offset, entry}, state.buffer)}
    end

    defp register_chunk(state, 0) do
      grant_credit(state)
    end

    defp register_chunk(%{chunk_remaining: 0} = state, n) do
      %{state | chunk_remaining: n}
    end

    defp register_chunk(state, n) do
      %{state | chunk_remainders: :queue.in(n, state.chunk_remainders)}
    end

    defp pop_message(%{reliable?: true, pending: {_, message}} = state) do
      {:ok, message, state}
    end

    defp pop_message(state) do
      case take_entry(state) do
        :empty ->
          {:empty, state}

        {:ok, {offset, data}, state} ->
          yield_or_skip(state, offset, data)
      end
    end

    defp yield_or_skip(state, offset, data) do
      topic = Mq.Topic.value(state.topic)

      case decode_entry(data, topic) do
        {:ok, message} ->
          hold_if_reliable(state, offset, message)

        :drop ->
          pop_message(state)
      end
    end

    defp hold_if_reliable(%{reliable?: true} = state, offset, message) do
      {:ok, message, %{state | pending: {offset, message}}}
    end

    defp hold_if_reliable(state, _offset, message) do
      {:ok, message, state}
    end

    defp take_entry(state) do
      case :queue.out(state.buffer) do
        {:empty, _} ->
          :empty

        {{:value, entry}, buffer} ->
          {:ok, entry, consume_slot(%{state | buffer: buffer})}
      end
    end

    defp decode_entry(data, topic) when is_binary(data) do
      case Codec.decode(data) do
        {:ok, message} -> {:ok, message}
        {:error, _} -> drop(topic)
      end
    end

    defp decode_entry(_data, topic), do: drop(topic)

    defp drop(topic) do
      :telemetry.execute(
        Telemetry.event([:mq, :stream, :decode_drop]),
        %{count: 1},
        %{topic: topic}
      )

      :drop
    end

    defp consume_slot(%{chunk_remaining: remaining} = state) when remaining > 1 do
      %{state | chunk_remaining: remaining - 1}
    end

    defp consume_slot(%{chunk_remaining: 1} = state) do
      state = grant_credit(state)

      case :queue.out(state.chunk_remainders) do
        {:empty, remainders} ->
          %{state | chunk_remaining: 0, chunk_remainders: remainders}

        {{:value, n}, remainders} ->
          %{state | chunk_remaining: n, chunk_remainders: remainders}
      end
    end

    # Пустой чанк или последний элемент чанка могут прийти уже после потери подписки:
    # `credit/3` объявлен с guard'ом `is_integer(subscription_id)` и уронил бы reader.
    defp grant_credit(%{subscription_id: nil} = state), do: state

    defp grant_credit(%{connection: conn, subscription_id: id} = state) do
      _ = conn.credit(id, 1)
      state
    end

    defp ensure_stream(conn, topic) do
      case conn.create_stream(topic) do
        :ok -> :ok
        {:error, :stream_already_exists} -> :ok
        {:error, _} = err -> err
      end
    end

    defp resolve_offset(conn, topic, subscriber, :stored) do
      case conn.query_offset(topic, subscriber) do
        {:ok, offset} -> {:offset, offset + 1}
        {:error, _} -> :first
      end
    end

    defp resolve_offset(_conn, _topic, _subscriber, :first), do: :first
    defp resolve_offset(_conn, _topic, _subscriber, :next), do: :next
    defp resolve_offset(_conn, _topic, _subscriber, :last), do: :last
    defp resolve_offset(_conn, _topic, _subscriber, {:offset, _} = offset), do: offset

    defp poll(server, deadline) do
      case get(server, 0) do
        {:ok, _} = ok ->
          ok

        :empty ->
          idle_or_poll(server, deadline)

        {:error, _} = err ->
          err
      end
    end

    defp idle_or_poll(server, deadline) do
      if timed_out?(deadline),
        do: :empty,
        else: poll_after_wait(server, deadline)
    end

    defp poll_after_wait(server, deadline) do
      Process.sleep(10)
      poll(server, deadline)
    end

    defp deadline(:infinity), do: :infinity

    defp deadline(ms) when is_integer(ms) do
      System.monotonic_time(:millisecond) + ms
    end

    defp timed_out?(:infinity), do: false

    defp timed_out?(deadline) when is_integer(deadline) do
      System.monotonic_time(:millisecond) >= deadline
    end
  end
end
