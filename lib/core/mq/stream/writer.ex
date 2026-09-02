defmodule Core.Mq.Stream.Writer do
  @moduledoc """
  `Mq.Writer` для RabbitMQ Stream: create_stream + declare_producer на topic.

  `publish` в клиенте — `GenServer.cast`, а кадры `publish_confirm` / `publish_error`
  библиотека выбрасывает: сам по себе publish ничего не подтверждает. Поэтому после
  каждой пачки writer сверяет `producer_sequence` по каждому затронутому топику и
  отвечает `:ok`, только когда брокер подтвердил последний `publishing_id`. Иначе
  outbox помечал бы записи `published` вслепую — at-most-once вместо at-least-once.

  Не подтверждённая пачка отдаётся как `{:error, 0, error}`: доказать, что часть
  сообщений всё же дошла, нельзя, поэтому повторяется вся пачка (дубли легальны —
  потребители идемпотентны).

  `producer_id` действителен только в рамках выдавшего его соединения, поэтому writer
  мониторит процесс `:connection` и на `:DOWN` сбрасывает кеш producers.

  Обязательные opts: `:connection` (модуль `use RabbitMQStream.Connection`),
  `:reference_prefix` (уникальный префикс producer reference).
  Опциональные: `:confirm_timeout_ms`, `:confirm_poll_ms`.
  """

  @behaviour Core.Mq.Writer

  use GenServer

  alias Core.Error
  alias Core.Helper.Transact
  alias Core.Mq
  alias Core.Mq.Codec
  alias Core.Mq.Message
  alias Core.Telemetry

  require Error
  require Logger

  @shutdown_ms 30_000
  @confirm_timeout_ms 5_000
  @confirm_poll_ms 20

  defstruct [
    :connection,
    :reference_prefix,
    :conn_ref,
    :confirm_timeout_ms,
    :confirm_poll_ms,
    producers: %{}
  ]

  @type producer_state :: {non_neg_integer(), non_neg_integer()}
  @type state :: %__MODULE__{
          connection: module(),
          reference_prefix: String.t(),
          conn_ref: reference() | nil,
          confirm_timeout_ms: pos_integer(),
          confirm_poll_ms: pos_integer(),
          producers: %{String.t() => producer_state()}
        }

  @doc """
  Спецификация ребёнка супервизора.

  `:shutdown` (default #{@shutdown_ms} мс) — запас на текущую пачку и удаление
  producer'ов в `terminate/2`: `put_many/2` идёт одним `call` без таймаута, и убивать
  writer раньше нельзя — producer'ы останутся висеть в брокере до таймаута соединения.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()

  def child_spec(opts) when is_list(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      shutdown: Keyword.get(opts, :shutdown, @shutdown_ms)
    }
  end

  @doc "Запустить writer."
  @spec start_link(keyword()) :: GenServer.on_start()

  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc "Опубликовать сообщение."
  @spec put(GenServer.server(), Message.t()) :: :ok | {:error, Error.t()}

  @impl true
  def put(server, %Message{} = message) do
    case put_many(server, [message]) do
      :ok -> :ok
      {:error, _index, %Error{} = error} -> {:error, error}
    end
  end

  @doc "Опубликовать сообщения по порядку в одном call; стоп на первой ошибке."
  @spec put_many(GenServer.server(), [Message.t()]) ::
          :ok | {:error, non_neg_integer(), Error.t()}

  @impl true
  def put_many(server, messages) when is_list(messages) do
    :ok = Transact.warn_in_transaction("публикация пачки в stream")

    GenServer.call(server, {:put_many, messages}, :infinity)
  end

  @doc false
  @impl true
  def init(opts) do
    # Producer'ы объявлены в брокере — внешний ресурс: без trap_exit штатная
    # остановка не вызовет terminate/2, и они останутся висеть до таймаута соединения.
    Process.flag(:trap_exit, true)

    state = %__MODULE__{
      connection: Keyword.fetch!(opts, :connection),
      reference_prefix: Keyword.fetch!(opts, :reference_prefix),
      conn_ref: nil,
      confirm_timeout_ms: Keyword.get(opts, :confirm_timeout_ms, @confirm_timeout_ms),
      confirm_poll_ms: Keyword.get(opts, :confirm_poll_ms, @confirm_poll_ms),
      producers: %{}
    }

    {:ok, state}
  end

  @doc false
  @impl true
  def handle_call({:put_many, messages}, _from, state) when is_list(messages) do
    case do_put_many(state, messages, 0) do
      {:ok, state} -> {:reply, confirm_batch(state, messages), state}
      {:error, index, error, state} -> {:reply, {:error, index, error}, state}
    end
  end

  @doc false
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %__MODULE__{conn_ref: ref} = state) do
    Logger.warning(
      "stream writer: соединение упало, кеш producers сброшен: reason=#{inspect(reason)}"
    )

    {:noreply, %{state | conn_ref: nil, producers: %{}}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @doc false
  @impl true
  def terminate(_reason, %__MODULE__{} = state) do
    Enum.each(state.producers, fn {topic, {producer_id, _sequence}} ->
      delete_producer(state, topic, producer_id)
    end)
  end

  # ---

  defp delete_producer(state, topic, producer_id) do
    _ = state.connection.delete_producer(producer_id)
    :ok
  rescue
    exception ->
      log_delete_failed(topic, exception)
  catch
    :exit, reason ->
      log_delete_failed(topic, reason)
  end

  defp log_delete_failed(topic, detail) do
    Logger.warning(
      "stream writer: не удалось удалить producer при остановке " <>
        "topic=#{topic} причина=#{inspect(detail)}"
    )
  end

  defp do_put_many(state, [], _index), do: {:ok, state}

  defp do_put_many(state, [message | rest], index) do
    case do_put_one(state, message) do
      {:ok, state} -> do_put_many(state, rest, index + 1)
      {:error, %Error{} = error, state} -> {:error, index, error, state}
    end
  end

  defp do_put_one(state, %Message{} = message) do
    topic = Mq.Topic.value(message.topic)
    start = System.monotonic_time()

    case ensure_producer(state, topic) do
      {:ok, state} ->
        publish_encoded(state, message, topic, start)

      {:error, %Error{} = error} ->
        emit_publish(start, :error, topic)
        {:error, error, state}
    end
  end

  defp publish_encoded(state, message, topic, start) do
    {producer_id, sequence} = Map.fetch!(state.producers, topic)
    next_seq = sequence + 1

    case Codec.encode(message) do
      {:ok, binary} ->
        :ok = state.connection.publish(producer_id, next_seq, binary)
        emit_publish(start, :ok, topic)
        producers = Map.put(state.producers, topic, {producer_id, next_seq})
        {:ok, %{state | producers: producers}}

      {:error, %Error{} = error} ->
        emit_publish(start, :error, topic)
        {:error, error, state}
    end
  end

  defp emit_publish(start, result, topic) do
    :telemetry.execute(
      Telemetry.event([:mq, :stream, :publish]),
      %{duration: System.monotonic_time() - start, count: 1},
      %{result: result, topic: topic}
    )
  end

  defp confirm_batch(state, messages) do
    messages
    |> Enum.map(&Mq.Topic.value(&1.topic))
    |> Enum.uniq()
    |> Enum.reduce_while(:ok, fn topic, :ok -> confirm_topic(state, topic) end)
  end

  defp confirm_topic(state, topic) do
    {_producer_id, sequence} = Map.fetch!(state.producers, topic)
    deadline = System.monotonic_time(:millisecond) + state.confirm_timeout_ms

    case await_sequence(state, topic, sequence, deadline) do
      :ok -> {:cont, :ok}
      {:error, %Error{} = error} -> {:halt, {:error, 0, error}}
    end
  end

  defp await_sequence(state, topic, sequence, deadline) do
    case state.connection.producer_sequence(topic, producer_reference(state, topic)) do
      {:ok, confirmed} when confirmed >= sequence -> :ok
      _not_yet -> retry_sequence(state, topic, sequence, deadline)
    end
  catch
    :exit, reason -> {:error, confirm_error(topic, {:exit, reason})}
  end

  defp retry_sequence(state, topic, sequence, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      emit_publish_unconfirmed(topic)
      {:error, confirm_error(topic, :timeout)}
    else
      Process.sleep(state.confirm_poll_ms)
      await_sequence(state, topic, sequence, deadline)
    end
  end

  defp emit_publish_unconfirmed(topic) do
    :telemetry.execute(
      Telemetry.event([:mq, :stream, :publish]),
      %{duration: 0, count: 1},
      %{result: :unconfirmed, topic: topic}
    )
  end

  defp confirm_error(topic, reason) do
    Logger.warning(
      "stream writer: публикация не подтверждена topic=#{topic} причина=#{inspect(reason)}"
    )

    Error.app(__MODULE__,
      code: :publish_unconfirmed,
      ns: :mq,
      message: "Брокер не подтвердил публикацию",
      detail: %{topic: topic, reason: reason}
    )
  end

  defp ensure_producer(%__MODULE__{producers: producers} = state, topic)
       when is_map_key(producers, topic) do
    {:ok, state}
  end

  # `connect/0` идемпотентен и обязателен: при `lazy: true` соединение само не подключается,
  # а молча буферизует запросы до таймаута `GenServer.call` — вместо ошибки producer
  # готовился бы 5 секунд и падал по exit.
  defp ensure_producer(%__MODULE__{} = state, topic) do
    conn = state.connection
    ref = producer_reference(state, topic)

    with {:ok, state} <- ensure_monitor(state),
         :ok <- conn.connect(),
         :ok <- ensure_stream(conn, topic),
         {:ok, producer_id} <- conn.declare_producer(topic, ref),
         {:ok, sequence} <- conn.producer_sequence(topic, ref) do
      Logger.info("stream writer: producer готов topic=#{topic} ref=#{ref} sequence=#{sequence}")
      {:ok, %{state | producers: Map.put(state.producers, topic, {producer_id, sequence})}}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, producer_setup_error(reason)}
    end
  catch
    :exit, reason -> {:error, producer_setup_error({:exit, reason})}
  end

  # Кеш producer_id обязан жить не дольше соединения, выдавшего его: иначе после
  # рестарта `Stream.Connection` publish уходит на мёртвый producer, а сверка
  # sequence — на новый, ещё пустой.
  defp ensure_monitor(%__MODULE__{conn_ref: ref} = state) when is_reference(ref), do: {:ok, state}

  defp ensure_monitor(%__MODULE__{} = state) do
    case GenServer.whereis(state.connection) do
      nil -> {:error, producer_setup_error(:connection_not_started)}
      pid -> {:ok, %{state | conn_ref: Process.monitor(pid)}}
    end
  end

  defp producer_setup_error(reason) do
    Error.app(__MODULE__,
      code: :producer_setup_failed,
      ns: :mq,
      message: "Не удалось подготовить producer stream",
      detail: reason
    )
  end

  defp producer_reference(%__MODULE__{reference_prefix: prefix}, topic), do: "#{prefix}:#{topic}"

  defp ensure_stream(conn, topic) do
    case conn.create_stream(topic) do
      :ok -> :ok
      {:error, :stream_already_exists} -> :ok
      {:error, _} = err -> err
    end
  end
end
