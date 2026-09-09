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
    (default 2) задаёт prefetch; потолок буфера ≈ `credit` чанков. Сам буфер и учёт
    кредитов — `Mq.Stream.Buffer`: reader только выдаёт брокеру то, что тот насчитал.
    Entries хранятся сырыми; `Codec.decode` — в `get`.

    Курсор двигает не только `commit/1`: запись, которую адаптер отбросил (нечитаемая,
    чужой топик, sub-entry batching), возвращаться не будет, поэтому её offset тоже
    сохраняется — одним `store_offset` на серию дропов, когда за ними не осталось
    читаемых записей.

    Подписка устанавливается не в `init/1`, а в `handle_continue/2`: сетевые вызовы в `init`
    блокировали бы старт всего дерева супервизии (см. `docs/rules/17-otp-concurrency.md`).
    Сбой подписки не роняет процесс — он повторяет попытку с backoff от `:retry_min_ms`
    до `:retry_max_ms`. Пока подписки нет, `get` отдаёт `:empty`: подписчики опрашивают
    reader каждые ~100 мс, и ошибка на каждом цикле залила бы лог. Недоступность видна
    по `warning` самого reader'а (их частота ограничена backoff'ом) и по `subscribed?`
    в `info/1` (уходит в метрику).

    Обязательные opts: `:connection`, `:topic`, `:subscriber_name`. Опциональные:
    `:reliable?` (default `true`), `:credit`, `:initial_offset`, `:retry_min_ms`,
    `:retry_max_ms`, `:name`, `:shutdown`. При `reliable?: false` cursor не сохраняется
    (`commit` недоступен).

    `initial_offset: :stored` (default) без сохранённого offset читает stream с начала
    (`:first`): новый подписчик на живом топике получит всю его историю. Нужен другой
    старт — задать `:next` или `:last` явно.
    """

    @behaviour Core.Mq.ReaderReliable

    use GenServer

    alias Core.Error
    alias Core.Helper.StartOpts
    alias Core.Mq
    alias Core.Mq.Message
    alias Core.Mq.Stream.Buffer
    alias Core.Mq.Stream.Codec
    alias Core.Telemetry
    alias RabbitMQStream.Message.Types.DeliverData
    alias RabbitMQStream.OsirisChunk

    require Error
    require Logger

    @shutdown_ms 15_000
    @call_timeout 5_000
    @retry_min_ms 1_000
    @retry_max_ms 30_000
    @initial_offsets ~w(stored first next last)a
    @label "Mq.Stream.Reader"

    defstruct [
      :connection,
      :topic,
      :topic_name,
      :subscriber_name,
      :subscriber,
      :subscription_id,
      :conn_ref,
      :reliable?,
      :credit,
      :initial_offset,
      :retry_min_ms,
      :retry_max_ms,
      :retry_ms,
      :buffer,
      pending: nil,
      dropped_offset: nil,
      mismatch_logged?: false
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

    @doc "Состояние буфера и курсора reader (для метрик и разбора)."
    @spec info(t()) :: %{
            buffer_len: non_neg_integer(),
            chunk_remaining: non_neg_integer(),
            dropped_offset: non_neg_integer() | nil,
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

      {:ok, build_state(opts), {:continue, :subscribe}}
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
        {:empty, state} -> {:reply, :empty, flush_dropped(state)}
      end
    end

    def handle_call(:info, _from, state) do
      info = %{
        buffer_len: Buffer.len(state.buffer),
        chunk_remaining: Buffer.remaining(state.buffer),
        dropped_offset: state.dropped_offset,
        pending?: not is_nil(state.pending),
        subscribed?: not is_nil(state.subscription_id),
        topic: state.topic_name
      }

      {:reply, info, state}
    end

    def handle_call(:commit, _from, %{reliable?: false} = state) do
      {:reply,
       {:error,
        Error.app(
          code: :not_reliable,
          ns: :mq,
          message: "Reader не в reliable-режиме"
        )}, state}
    end

    def handle_call(:commit, _from, %{pending: nil} = state) do
      {:reply,
       {:error,
        Error.app(
          code: :nothing_to_commit,
          ns: :mq,
          message: "Нет сообщения для commit"
        )}, state}
    end

    # `store_offset` в клиенте — `GenServer.cast`: подтверждения сохранения нет, и обрыв
    # соединения виден только как exit по таймауту. Потеря offset безопасна (сообщение
    # переедет повторно), а вот падение reader'а на ней — нет.
    def handle_call(:commit, _from, %{pending: {offset, _message}} = state) do
      case store_offset(state, offset) do
        :ok -> {:reply, :ok, %{state | pending: nil, dropped_offset: nil}}
        {:error, %Error{} = error} -> {:reply, {:error, error}, state}
      end
    end

    @doc false
    @impl true
    def handle_info(:resubscribe, state) do
      {:noreply, subscribe(state)}
    end

    # Чанк, пришедший без подписки (её потеряли между отправкой и доставкой), потреблять
    # некому: `get` отдаёт `:empty`, а переподписка сбросит буфер. В метрику доставленного
    # он тоже не идёт — прочитан он не будет.
    def handle_info({:deliver, %DeliverData{}}, %__MODULE__{subscription_id: nil} = state) do
      {:noreply, state}
    end

    def handle_info(
          {:deliver,
           %DeliverData{osiris_chunk: %OsirisChunk{num_records: n, num_entries: n} = chunk}},
          state
        ) do
      emit_deliver(state.topic_name, chunk.num_entries)

      entries =
        chunk.data_entries
        |> List.wrap()
        |> Enum.with_index(fn entry, idx -> {chunk.chunk_id + idx, entry} end)

      {:noreply, put_chunk(state, entries)}
    end

    # Offset записи считается как `chunk_id + idx`, и это верно, только пока entry несёт
    # ровно одну запись. При sub-entry batching (`num_records > num_entries`) клиент entry
    # не распаковывает, и `store_offset` коммитил бы чужой offset. Такой чанк дропается
    # целиком: молча разъехавшийся курсор хуже потерянных сообщений.
    def handle_info({:deliver, %DeliverData{osiris_chunk: %OsirisChunk{} = chunk}}, state) do
      emit_deliver(state.topic_name, chunk.num_entries)

      Logger.error(
        "stream reader: чанк с sub-entry batching пропущен, offset'ы не восстановимы: " <>
          "topic=#{state.topic_name} num_entries=#{chunk.num_entries} " <>
          "num_records=#{chunk.num_records}"
      )

      emit_decode_drop(state.topic_name, chunk.num_entries)

      {:noreply, put_chunk(state, [])}
    end

    # `subscription_id` действителен только в рамках выдавшего его соединения: без этой
    # ветки после рестарта `Stream.Connection` подписка мертва навсегда, а `info/1`
    # продолжает отдавать `subscribed?: true` — алерт молчит.
    def handle_info({:DOWN, ref, :process, _pid, reason}, %__MODULE__{conn_ref: ref} = state) do
      {:noreply, schedule_resubscribe(%{state | conn_ref: nil}, {:connection_down, reason})}
    end

    def handle_info(_other, state), do: {:noreply, state}

    @doc false
    @impl true
    def terminate(_reason, %{subscription_id: nil}), do: :ok

    # Накопленный дроп сохраняется здесь же: иначе штатная остановка отдаёт его назад
    # брокеру, и хвост нечитаемых записей перебирается заново на следующем старте.
    def terminate(_reason, %{connection: conn, subscription_id: id} = state) do
      _ = flush_dropped(state)
      _ = conn.unsubscribe(id)
      :ok
    end

    # ---

    defp build_state(opts) do
      retry_min_ms = StartOpts.pos_integer!(@label, opts, :retry_min_ms, @retry_min_ms)
      topic = StartOpts.prim!(@label, opts, :topic, Mq.Topic)
      subscriber_name = StartOpts.prim!(@label, opts, :subscriber_name, Mq.SubscriberName)

      %__MODULE__{
        connection: StartOpts.module!(@label, opts, :connection),
        topic: topic,
        topic_name: Mq.Topic.value(topic),
        subscriber_name: subscriber_name,
        subscriber: Mq.SubscriberName.value(subscriber_name),
        subscription_id: nil,
        conn_ref: nil,
        reliable?: StartOpts.boolean!(@label, opts, :reliable?, true),
        credit: StartOpts.pos_integer!(@label, opts, :credit, 2),
        initial_offset: initial_offset!(opts),
        retry_min_ms: retry_min_ms,
        retry_max_ms: StartOpts.pos_integer!(@label, opts, :retry_max_ms, @retry_max_ms),
        retry_ms: retry_min_ms,
        buffer: Buffer.new()
      }
    end

    # `{:offset, n}` не перечислить множеством, поэтому клоза, а не `StartOpts.one_of!/5`:
    # без проверки такой offset доходит до `resolve_offset/4` и роняет `handle_continue/2`
    # `FunctionClauseError` — процесс не стартует ни с одной попытки.
    defp initial_offset!(opts) do
      case Keyword.get(opts, :initial_offset, :stored) do
        {:offset, n} = offset when is_integer(n) and n >= 0 ->
          offset

        named when named in @initial_offsets ->
          named

        other ->
          StartOpts.raise_invalid!(
            @label,
            :initial_offset,
            "одно из #{inspect(@initial_offsets)} или {:offset, n}",
            other
          )
      end
    end

    defp subscribe(%__MODULE__{} = state) do
      case try_subscribe(state) do
        {:ok, subscription_id} ->
          Logger.info(
            "stream reader подписан: topic=#{state.topic_name} subscriber=#{state.subscriber}"
          )

          state =
            state
            |> reset_stream_state()
            |> remonitor()

          %{state | subscription_id: subscription_id, retry_ms: state.retry_min_ms}

        {:error, reason} ->
          schedule_resubscribe(state, reason)
      end
    end

    # Буфер, счётчики чанков и `pending` принадлежат конкретной подписке: перенос их в
    # новую даёт дубли (записи придут заново от сохранённого offset) и дрейф кредитов —
    # `grant_credit` начал бы выдавать кредиты по учёту предыдущей подписки.
    defp reset_stream_state(%__MODULE__{} = state) do
      %{
        state
        | subscription_id: nil,
          buffer: Buffer.new(),
          pending: nil,
          dropped_offset: nil,
          mismatch_logged?: false
      }
    end

    defp remonitor(%__MODULE__{conn_ref: ref} = state) do
      if is_reference(ref), do: Process.demonitor(ref, [:flush])

      case GenServer.whereis(state.connection) do
        nil -> %{state | conn_ref: nil}
        pid -> %{state | conn_ref: Process.monitor(pid)}
      end
    end

    defp store_offset(state, offset) do
      state.connection.store_offset(state.topic_name, state.subscriber, offset)
      :ok
    catch
      :exit, reason ->
        Logger.warning(
          "stream reader: commit не доставлен topic=#{state.topic_name} " <>
            "subscriber=#{state.subscriber} reason=#{inspect(reason)}"
        )

        {:error,
         Error.app(
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
    defp try_subscribe(%__MODULE__{} = state) do
      with :ok <- state.connection.connect(),
           :ok <- ensure_stream(state.connection, state.topic_name),
           offset <- resolve_offset(state, state.initial_offset) do
        state.connection.subscribe(state.topic_name, self(), offset, state.credit)
      end
    catch
      :exit, reason -> {:error, {:exit, reason}}
    end

    defp schedule_resubscribe(%__MODULE__{} = state, reason) do
      Logger.warning(
        "stream reader: подписка не удалась topic=#{state.topic_name} " <>
          "subscriber=#{state.subscriber} reason=#{inspect(reason)} retry_in=#{state.retry_ms}ms"
      )

      Process.send_after(self(), :resubscribe, state.retry_ms)

      %{reset_stream_state(state) | retry_ms: next_retry_ms(state)}
    end

    defp next_retry_ms(%__MODULE__{retry_ms: retry_ms, retry_max_ms: max_ms}) do
      min(retry_ms * 2, max_ms)
    end

    defp emit_deliver(topic, entries) do
      :telemetry.execute(
        Telemetry.event([:mq, :stream, :deliver]),
        %{entries: entries},
        %{topic: topic}
      )
    end

    defp put_chunk(state, entries) do
      {buffer, credits} = Buffer.put_chunk(state.buffer, entries)

      grant_credits(%{state | buffer: buffer}, credits)
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
      case decode_entry(state, data) do
        {:ok, message} ->
          hold_if_reliable(state, offset, message)

        {:drop, state} ->
          state
          |> commit_dropped(offset)
          |> pop_message()
      end
    end

    # Отброшенная запись не вернётся: повтор даст тот же дроп. Без сохранения её offset
    # курсор остаётся позади, и если валидных записей за ней не окажется, после рестарта
    # reader переберёт и отбросит тот же хвост заново. Пишется он не сразу: чанк из
    # полусотни нечитаемых записей дал бы полсотни cast'ов, а на оборванном соединении —
    # столько же `warning` из `store_offset/4`. Копится последний offset серии.
    defp commit_dropped(%{reliable?: true} = state, offset) do
      %{state | dropped_offset: offset}
    end

    defp commit_dropped(state, _offset), do: state

    # Серия дропов сохраняется одним вызовом — когда за ней не осталось читаемых записей.
    # `commit/1` подписчика её перекрывает: его offset всегда выше.
    defp flush_dropped(%{reliable?: true, dropped_offset: offset} = state)
         when is_integer(offset) do
      _ = store_offset(state, offset)

      %{state | dropped_offset: nil}
    end

    defp flush_dropped(state), do: state

    defp hold_if_reliable(%{reliable?: true} = state, offset, message) do
      {:ok, message, %{state | pending: {offset, message}}}
    end

    defp hold_if_reliable(state, _offset, message) do
      {:ok, message, state}
    end

    defp take_entry(state) do
      case Buffer.take(state.buffer) do
        {:empty, _buffer} ->
          :empty

        {:ok, entry, buffer, credits} ->
          {:ok, entry, grant_credits(%{state | buffer: buffer}, credits)}
      end
    end

    defp decode_entry(state, data) when is_binary(data) do
      case Codec.decode(data) do
        {:ok, message} -> ensure_topic(state, message)
        {:error, _} -> {:drop, drop(state)}
      end
    end

    # Топик в конверте пишет продюсер, а позицию записи в потоке задаёт подписка: запись
    # с чужим топиком ушла бы в handler как своя. Адаптер не отдаёт наверх то, чью
    # принадлежность не может подтвердить, — дроп, как у нечитаемой записи.
    defp ensure_topic(%{topic_name: topic} = state, %Message{topic: envelope_topic} = message) do
      case Mq.Topic.value(envelope_topic) do
        ^topic -> {:ok, message}
        other -> {:drop, drop(log_mismatch(state, other))}
      end
    end

    # Чужой топик в конверте — состояние мисконфигурации, а не разовое событие: поток
    # таких записей залил бы лог на полной скорости чтения. Пишется первая запись на
    # подписку, дальше о них говорит только `decode_drop`.
    defp log_mismatch(%{mismatch_logged?: true} = state, _other), do: state

    defp log_mismatch(state, other) do
      Logger.warning(
        "stream reader: topic конверта не совпадает с подпиской, записи пропускаются: " <>
          "topic=#{state.topic_name} конверт=#{other}"
      )

      %{state | mismatch_logged?: true}
    end

    defp drop(state) do
      emit_decode_drop(state.topic_name, 1)
      state
    end

    defp emit_decode_drop(topic, count) do
      :telemetry.execute(
        Telemetry.event([:mq, :stream, :decode_drop]),
        %{count: count},
        %{topic: topic}
      )
    end

    defp grant_credits(state, 0), do: state

    # Последний элемент чанка может быть выбран уже после потери подписки: `credit/3`
    # объявлен с guard'ом `is_integer(subscription_id)` и уронил бы reader.
    defp grant_credits(%{subscription_id: nil} = state, _credits), do: state

    defp grant_credits(%{connection: conn, subscription_id: id} = state, credits) do
      _ = conn.credit(id, credits)
      state
    end

    defp ensure_stream(conn, topic) do
      case conn.create_stream(topic) do
        :ok -> :ok
        {:error, :stream_already_exists} -> :ok
        {:error, _} = err -> err
      end
    end

    defp resolve_offset(state, :stored) do
      case state.connection.query_offset(state.topic_name, state.subscriber) do
        {:ok, offset} -> {:offset, offset + 1}
        {:error, _} -> :first
      end
    end

    defp resolve_offset(_state, :first), do: :first
    defp resolve_offset(_state, :next), do: :next
    defp resolve_offset(_state, :last), do: :last
    defp resolve_offset(_state, {:offset, _} = offset), do: offset

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
