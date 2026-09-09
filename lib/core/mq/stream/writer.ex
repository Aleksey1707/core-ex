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
  потребители идемпотентны). Дедлайн подтверждения — `:confirm_timeout_ms` на **пачку**,
  а не на топик, и producer неподтверждённого топика забывается: его локальный
  `sequence` ушёл вперёд брокерского, и следующая пачка объявляет producer заново.

  `producer_id` действителен только в рамках выдавшего его соединения, поэтому writer
  мониторит процесс `:connection` и на `:DOWN` сбрасывает кеш producers.

  Кеш producers ограничен `:max_producers` (default 256): каждый producer занят и в
  брокере, а снимаются они только в `terminate/2`, по `:DOWN` и при неподтверждении.
  Переполнение вытесняет топик, в который дольше всех не публиковали, — на границе
  пачки, а не по ходу: внутри неё кеш только растёт, иначе вытеснение сняло бы producer
  топика, который эта же пачка ещё подтверждает.

  Обязательные opts: `:connection` (модуль `use RabbitMQStream.Connection`),
  `:reference_prefix` (уникальный префикс producer reference). Опциональные:
  `:confirm_timeout_ms`, `:confirm_poll_ms`, `:max_producers`, `:name`, `:shutdown`.
  """

  @behaviour Core.Mq.Writer

  use GenServer

  alias Core.Error
  alias Core.Helper.StartOpts
  alias Core.Helper.Transact
  alias Core.Mq
  alias Core.Mq.Message
  alias Core.Mq.Stream.Codec
  alias Core.Telemetry

  require Error
  require Logger

  @shutdown_ms 30_000
  @confirm_timeout_ms 5_000
  @confirm_poll_ms 20
  @max_producers 256
  @label "Mq.Stream.Writer"

  defstruct [
    :connection,
    :reference_prefix,
    :conn_ref,
    :confirm_timeout_ms,
    :confirm_poll_ms,
    :max_producers,
    producers: %{},
    usage_tick: 0
  ]

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

    {:ok, build_state(opts)}
  end

  @doc false
  @impl true
  def handle_call({:put_many, messages}, _from, state) when is_list(messages) do
    topics = batch_topics(messages)

    case do_put_many(state, messages, 0) do
      {:ok, state} ->
        {result, state} = confirm_batch(state, topics)

        {:reply, result, close_batch(state, topics)}

      {:error, index, error, state} ->
        {:reply, {:error, index, error}, close_batch(state, topics)}
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
    Enum.each(state.producers, fn {topic, {producer_id, _sequence, _used}} ->
      delete_producer(state, topic, producer_id)
    end)
  end

  # ---

  defp build_state(opts) do
    %__MODULE__{
      connection: StartOpts.module!(@label, opts, :connection),
      reference_prefix: StartOpts.binary!(@label, opts, :reference_prefix),
      conn_ref: nil,
      confirm_timeout_ms:
        StartOpts.pos_integer!(@label, opts, :confirm_timeout_ms, @confirm_timeout_ms),
      confirm_poll_ms: StartOpts.pos_integer!(@label, opts, :confirm_poll_ms, @confirm_poll_ms),
      max_producers: StartOpts.pos_integer!(@label, opts, :max_producers, @max_producers),
      producers: %{},
      usage_tick: 0
    }
  end

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
    {producer_id, sequence, used} = Map.fetch!(state.producers, topic)
    next_seq = sequence + 1

    case Codec.encode(message) do
      {:ok, binary} ->
        :ok = state.connection.publish(producer_id, next_seq, binary)
        emit_publish(start, :ok, topic)
        producers = Map.put(state.producers, topic, {producer_id, next_seq, used})
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

  defp batch_topics(messages) do
    messages
    |> Enum.map(&Mq.Topic.value(&1.topic))
    |> Enum.uniq()
  end

  # Дедлайн один на всю пачку: `confirm_timeout_ms` на каждый топик давал бы ожидание,
  # кратное числу топиков, а `:shutdown` writer'а и вызывающего поллера рассчитан на
  # пачку целиком — супервизор добил бы обоих посреди подтверждения.
  defp confirm_batch(state, topics) do
    deadline = System.monotonic_time(:millisecond) + state.confirm_timeout_ms

    Enum.reduce_while(topics, {:ok, state}, fn topic, {:ok, state} ->
      confirm_topic(state, topic, deadline)
    end)
  end

  # Кеш снимается только по таймауту: там локальный `sequence` разошёлся с брокерским.
  # Оборванное соединение (`:exit`) кеш чистит сама ветка `:DOWN` — снимать producer'а
  # ещё и здесь значило бы пересоздавать его на каждой пачке, пока брокер недоступен.
  defp confirm_topic(state, topic, deadline) do
    {_producer_id, sequence, _used} = Map.fetch!(state.producers, topic)

    case await_sequence(state, topic, sequence, deadline) do
      :ok ->
        {:cont, {:ok, state}}

      {:error, :timeout, %Error{} = error} ->
        {:halt, {{:error, 0, error}, forget_producer(state, topic)}}

      {:error, _reason, %Error{} = error} ->
        {:halt, {{:error, 0, error}, state}}
    end
  end

  defp await_sequence(state, topic, sequence, deadline) do
    case state.connection.producer_sequence(topic, producer_reference(state, topic)) do
      {:ok, confirmed} when confirmed >= sequence -> :ok
      _not_yet -> retry_sequence(state, topic, sequence, deadline)
    end
  catch
    :exit, reason -> {:error, :exit, confirm_error(topic, {:exit, reason})}
  end

  defp retry_sequence(state, topic, sequence, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      emit_publish_unconfirmed(topic)
      {:error, :timeout, confirm_error(topic, :timeout)}
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

    Error.app(
      code: :publish_unconfirmed,
      ns: :mq,
      message: "Брокер не подтвердил публикацию",
      detail: %{topic: topic, reason: reason}
    )
  end

  # Кеш producer'а не должен пережить неподтверждённую пачку: локальный `sequence` ушёл
  # вперёд брокерского, и следующая пачка сверялась бы с числом, которое брокер уже не
  # подтвердит. Producer снимается и в брокере — иначе он висит до таймаута соединения,
  # а `terminate/2` о нём больше не знает.
  defp forget_producer(state, topic) do
    case Map.pop(state.producers, topic) do
      {nil, _producers} ->
        state

      {{producer_id, _sequence, _used}, producers} ->
        delete_producer(state, topic, producer_id)
        %{state | producers: producers}
    end
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

      {:ok, put_producer(state, topic, producer_id, sequence)}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, producer_setup_error(reason)}
    end
  catch
    :exit, reason -> {:error, producer_setup_error({:exit, reason})}
  end

  defp put_producer(%__MODULE__{} = state, topic, producer_id, sequence) do
    tick = state.usage_tick + 1
    producers = Map.put(state.producers, topic, {producer_id, sequence, tick})

    %{state | producers: producers, usage_tick: tick}
  end

  # Метка свежести ставится раз на пачку, а не на сообщение: внутри одной пачки порядок
  # топиков между собой не важен, а перестройка карты на каждое сообщение — только мусор.
  # Топика может уже не быть: его producer снят неподтверждением или пачка была неудачной.
  defp touch_producers(%__MODULE__{} = state, topics) do
    Enum.reduce(topics, state, fn topic, state ->
      case Map.fetch(state.producers, topic) do
        {:ok, {producer_id, sequence, _used}} -> put_producer(state, topic, producer_id, sequence)
        :error -> state
      end
    end)
  end

  defp close_batch(%__MODULE__{} = state, topics) do
    state
    |> touch_producers(topics)
    |> evict_producers()
  end

  # Кеш не может расти вместе с числом топиков: каждый producer занят и в брокере, а
  # снимались они только в `terminate/2` и по `:DOWN`. Вытесняется тот, в который дольше
  # всех не публиковали; следующая публикация в него объявит producer заново и перечитает
  # sequence у брокера — тот же путь, что после неподтверждённой пачки.
  defp evict_producers(%__MODULE__{producers: producers, max_producers: max} = state)
       when map_size(producers) > max do
    {topic, _producer} = Enum.min_by(producers, fn {_topic, {_id, _seq, used}} -> used end)

    evict_producers(forget_producer(state, topic))
  end

  defp evict_producers(%__MODULE__{} = state), do: state

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
    Error.app(
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
