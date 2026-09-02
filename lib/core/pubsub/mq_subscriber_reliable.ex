defmodule Core.PubSub.MqSubscriberReliable do
  @moduledoc """
  `PubSub.Subscriber` поверх `Mq.ReaderReliable`.

  Успех / `{:skip, _}` → `commit`. Ошибка handler/decode → без commit (redelivery).
  Цикл не останавливается на ошибках handler. Необработанное исключение внутри
  `on_message`/`from_message` перехватывается и превращается в `{:error, %Error{}}`
  (без commit, redelivery) — не роняет подписчик в crash-loop на «ядовитом» сообщении.

  Повторы одного и того же сообщения считаются: интервал растёт от `poll_interval_ms`
  до `retry_max_ms`, а после `max_attempts` неудач сообщение уходит в DLQ-топик
  (`dlq_topic`, по умолчанию `"<topic>.dlq"`) и коммитится — иначе оно блокировало бы
  топик навсегда. Без настроенного `dlq_writer` выброса не происходит: подписчик
  продолжает повторы на `retry_max_ms` и пишет `error` в лог.

  После `:processed` / `:dlq` — немедленный следующий tick (`schedule(0)`, drain).
  После `:idle` — `poll_interval_ms`, после `:error` — текущий backoff.
  """

  @behaviour Core.PubSub.Subscriber

  use GenServer

  alias Core.Context
  alias Core.Error
  alias Core.Mq
  alias Core.Mq.Message
  alias Core.PubSub
  alias Core.Repo
  alias Core.Telemetry

  require Logger
  require Error

  @shutdown_ms 30_000
  @call_timeout 5_000
  @default_poll_interval_ms 100
  @default_max_attempts 5
  @default_retry_max_ms 30_000

  defstruct [
    :reader_module,
    :reader,
    :from_message,
    :on_message,
    :context_factory,
    :poll_interval_ms,
    :retry_max_ms,
    :retry_ms,
    :max_attempts,
    :dlq_writer,
    :dlq_handle,
    :dlq_topic,
    :topic,
    :data,
    :timer_ref,
    :pending_raw,
    attempts: 0,
    subscribed?: false
  ]

  @type domain_message :: term()
  @type subscriber_data :: term()

  @type from_message :: (Message.t() -> {:ok, domain_message()} | {:error, Error.t()})

  @type on_message ::
          (domain_message(), subscriber_data(), Context.t() -> PubSub.handler_result())

  @type t :: GenServer.server()

  @typedoc "Исход одного цикла чтения."
  @type cycle_result :: :processed | :dlq | :idle | :error | :not_subscribed

  @doc """
  Спецификация ребёнка супервизора.

  `:shutdown` (default #{@shutdown_ms} мс) — запас на единицу работы: обработка
  сообщения и commit offset идут целиком в одном колбэке под `trap_exit`, и остановка
  на середине переотправила бы уже обработанное сообщение.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()

  def child_spec(opts) when is_list(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      shutdown: Keyword.get(opts, :shutdown, @shutdown_ms)
    }
  end

  @doc """
  Запустить reliable subscriber.

  Opts: `:reader_module`, `:reader`, `:from_message`, `:on_message`,
  опционально `:context_factory` (вызывается на каждое сообщение), `:poll_interval_ms`,
  `:topic` (string для метрик и имени DLQ), `:name`.

  DLQ: `:dlq_writer` (модуль `Mq.Writer`), `:dlq_handle` (его handle),
  `:dlq_topic` (по умолчанию `"<topic>.dlq"`), `:max_attempts`, `:retry_max_ms`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()

  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc "Подписаться на чтение сообщений."
  @spec subscribe(t(), subscriber_data(), Context.t()) :: :ok | {:error, Error.t()}

  @impl true
  def subscribe(server, data, %Context{}) do
    GenServer.call(server, {:subscribe, data}, @call_timeout)
  end

  @doc "Отписаться от чтения."
  @spec unsubscribe(t(), Context.t()) :: :ok | {:error, Error.t()}

  @impl true
  def unsubscribe(server, %Context{}) do
    GenServer.call(server, :unsubscribe, @call_timeout)
  end

  @doc "Один цикл чтения (для тестов)."
  @spec run_once(t()) :: cycle_result()

  def run_once(server) do
    GenServer.call(server, :run_once, @call_timeout)
  end

  @doc false
  @impl true
  def init(opts) do
    # Обработка сообщения идёт целиком внутри одного handle_info: trap_exit даёт
    # ей завершиться и закоммитить offset вместо повторной доставки после рестарта.
    Process.flag(:trap_exit, true)
    poll_interval_ms = Keyword.get(opts, :poll_interval_ms, @default_poll_interval_ms)
    topic = topic_from_opts(opts)

    state = %__MODULE__{
      reader_module: Keyword.fetch!(opts, :reader_module),
      reader: Keyword.fetch!(opts, :reader),
      from_message: Keyword.fetch!(opts, :from_message),
      on_message: Keyword.fetch!(opts, :on_message),
      context_factory: Keyword.get(opts, :context_factory, &Context.new/0),
      poll_interval_ms: poll_interval_ms,
      retry_max_ms: retry_max_ms(opts, poll_interval_ms),
      retry_ms: poll_interval_ms,
      max_attempts: Keyword.get(opts, :max_attempts, @default_max_attempts),
      dlq_writer: Keyword.get(opts, :dlq_writer),
      dlq_handle: Keyword.get(opts, :dlq_handle),
      dlq_topic: dlq_topic(opts, topic),
      topic: topic,
      data: nil,
      timer_ref: nil,
      pending_raw: nil,
      attempts: 0,
      subscribed?: false
    }

    {:ok, state}
  end

  @doc false
  @impl true
  def handle_call({:subscribe, _data}, _from, %__MODULE__{subscribed?: true} = state) do
    error =
      Error.app(__MODULE__, code: :already_subscribed, ns: :pubsub, message: "Уже подписан")

    {:reply, {:error, error}, state}
  end

  def handle_call({:subscribe, data}, _from, state) do
    state = %{state | data: data, subscribed?: true}
    {:reply, :ok, schedule(state, state.poll_interval_ms)}
  end

  def handle_call(:unsubscribe, _from, state) do
    state = cancel_timer(state)
    {:reply, :ok, %{state | subscribed?: false, data: nil, pending_raw: nil, attempts: 0}}
  end

  def handle_call(:run_once, _from, %__MODULE__{subscribed?: false} = state) do
    emit_cycle(state, :not_subscribed)
    {:reply, :not_subscribed, state}
  end

  def handle_call(:run_once, _from, state) do
    {result, state} = consume_once(state)
    emit_cycle(state, result)
    {:reply, result, state}
  end

  @doc false
  @impl true
  def handle_info(:tick, %__MODULE__{subscribed?: false} = state) do
    {:noreply, state}
  end

  def handle_info(:tick, state) do
    state = cancel_timer(state)
    {result, state} = consume_once(state)
    emit_cycle(state, result)
    {:noreply, reschedule(state, result)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # ---

  defp consume_once(state) do
    case state.reader_module.get(state.reader, 0) do
      :empty ->
        {:idle, state}

      {:ok, raw} ->
        handle_raw(count_attempt(state, raw), raw)

      {:error, %Error{} = error} ->
        Logger.warning("pubsub reliable get: #{error.message}")
        {:error, state}
    end
  end

  # Тот же raw, что и на прошлом цикле, — очередная попытка: reliable-reader отдаёт
  # неподтверждённое сообщение повторно, пока не пришёл commit.
  defp count_attempt(%__MODULE__{pending_raw: raw} = state, raw) do
    %{state | attempts: state.attempts + 1}
  end

  defp count_attempt(state, raw) do
    %{state | pending_raw: raw, attempts: 1, retry_ms: state.poll_interval_ms}
  end

  defp handle_raw(state, raw) do
    case safe_from_message(state, raw) do
      {:ok, message} ->
        dispatch(state, raw, message)

      {:error, %Error{} = error} ->
        Logger.warning("pubsub reliable from_message: #{error.message}")
        fail_attempt(state, raw, error)
    end
  end

  defp safe_from_message(state, raw) do
    state.from_message.(raw)
  rescue
    exception -> {:error, handler_crash_error(:from_message, exception, __STACKTRACE__)}
  end

  # Контекст создаётся на сообщение и уничтожается после него: `Repo.Sc` держит эталоны
  # в ETS, и один контекст на весь uptime подписчика рос бы неограниченно, отдавая
  # write-репозиториям устаревшие эталоны.
  defp dispatch(%__MODULE__{} = state, raw, message) do
    context = state.context_factory.()

    try do
      do_dispatch(state, raw, message, context)
    after
      Repo.Sc.delete(context)
    end
  end

  defp do_dispatch(%__MODULE__{} = state, raw, message, context) do
    case safe_on_message(state, message, context) do
      :ok ->
        succeed(state)

      {:skip, _reason} ->
        succeed(state)

      {:error, %Error{} = error} ->
        Logger.warning("pubsub reliable on_message: #{error.message}")
        fail_attempt(state, raw, error)

      other ->
        Logger.warning("pubsub reliable on_message: unexpected result #{inspect(other)}")
        fail_attempt(state, raw, unexpected_result_error(other))
    end
  end

  defp safe_on_message(state, message, context) do
    state.on_message.(message, state.data, context)
  rescue
    exception -> {:error, handler_crash_error(:on_message, exception, __STACKTRACE__)}
  end

  defp succeed(state) do
    commit(state)
    {:processed, clear_pending(state)}
  end

  defp fail_attempt(%__MODULE__{} = state, raw, error) do
    if state.attempts >= state.max_attempts,
      do: exhausted(state, raw, error),
      else: {:error, state}
  end

  defp exhausted(%__MODULE__{dlq_writer: nil} = state, _raw, error) do
    Logger.error(
      "pubsub reliable: сообщение не обработано за #{state.attempts} попыток, " <>
        "DLQ не настроен, повторы продолжаются: topic=#{state.topic} " <>
        "ошибка=#{Error.format_chain(error)}"
    )

    {:error, state}
  end

  defp exhausted(%__MODULE__{} = state, raw, error) do
    case publish_to_dlq(state, raw, error) do
      :ok ->
        commit(state)
        log_dlq(state, error)
        emit_dlq(state)
        {:dlq, clear_pending(state)}

      {:error, %Error{} = dlq_error} ->
        Logger.error(
          "pubsub reliable: не удалось отправить сообщение в DLQ, оно остаётся в топике: " <>
            "topic=#{state.topic} dlq=#{state.dlq_topic} " <>
            "ошибка=#{Error.format_chain(dlq_error)}"
        )

        {:error, state}
    end
  end

  # За writer'ом стоит `GenServer.call`: недоступный процесс приходит как exit,
  # а не как `{:error, _}` — без этой ветки сбой DLQ ронял бы подписчика.
  defp publish_to_dlq(%__MODULE__{} = state, %Message{} = raw, error) do
    with {:ok, topic} <- Mq.Topic.new(state.dlq_topic),
         {:ok, message} <- Message.new(topic, dlq_headers(state, raw, error), raw.body, raw.key) do
      state.dlq_writer.put(state.dlq_handle, message)
    end
  rescue
    exception -> {:error, dlq_publish_error(exception)}
  catch
    :exit, reason -> {:error, dlq_publish_error(reason)}
  end

  defp dlq_publish_error(detail) do
    Error.app(__MODULE__,
      code: :dlq_publish_failed,
      ns: :pubsub,
      message: "Не удалось опубликовать сообщение в DLQ",
      detail: detail
    )
  end

  defp dlq_headers(%__MODULE__{} = state, %Message{headers: headers}, error) do
    Map.merge(headers, %{
      "x-dlq-source-topic" => state.topic,
      "x-dlq-attempts" => Integer.to_string(state.attempts),
      "x-dlq-error" => String.slice(Error.format_chain(error), 0, 1000)
    })
  end

  defp log_dlq(%__MODULE__{} = state, error) do
    Logger.error(
      "pubsub reliable: сообщение отправлено в DLQ после #{state.attempts} попыток: " <>
        "topic=#{state.topic} dlq=#{state.dlq_topic} ошибка=#{Error.format_chain(error)}"
    )
  end

  defp clear_pending(state) do
    %{state | pending_raw: nil, attempts: 0, retry_ms: state.poll_interval_ms}
  end

  defp handler_crash_error(handler, exception, stacktrace) do
    Error.app(__MODULE__,
      code: :handler_crashed,
      ns: :pubsub,
      message: "#{handler} завершился исключением",
      detail: %{exception: exception, stacktrace: stacktrace}
    )
  end

  defp unexpected_result_error(other) do
    Error.app(__MODULE__,
      code: :unexpected_handler_result,
      ns: :pubsub,
      message: "on_message вернул неожиданный результат",
      detail: other
    )
  end

  defp commit(state) do
    case state.reader_module.commit(state.reader) do
      :ok ->
        :ok

      {:error, %Error{} = error} ->
        Logger.warning("pubsub reliable commit: #{error.message}")
    end
  end

  defp reschedule(state, result) when result in ~w(processed dlq)a do
    schedule(state, 0)
  end

  defp reschedule(state, :error) do
    next = min(state.retry_ms * 2, state.retry_max_ms)
    schedule(%{state | retry_ms: next}, state.retry_ms)
  end

  defp reschedule(state, _other) do
    schedule(state, state.poll_interval_ms)
  end

  defp schedule(%__MODULE__{} = state, ms) when is_integer(ms) and ms >= 0 do
    state = cancel_timer(state)
    %{state | timer_ref: Process.send_after(self(), :tick, ms)}
  end

  defp cancel_timer(%__MODULE__{timer_ref: nil} = state), do: state

  defp cancel_timer(%__MODULE__{timer_ref: ref} = state) do
    _ = Process.cancel_timer(ref)
    %{state | timer_ref: nil}
  end

  defp emit_cycle(state, result) do
    :telemetry.execute(
      Telemetry.event([:mq, :subscriber, :cycle]),
      %{count: 1},
      %{result: result, topic: state.topic}
    )
  end

  defp emit_dlq(state) do
    :telemetry.execute(
      Telemetry.event([:mq, :subscriber, :dlq]),
      %{count: 1},
      %{topic: state.topic, dlq_topic: state.dlq_topic}
    )
  end

  defp topic_from_opts(opts) do
    case Keyword.get(opts, :topic) do
      topic when is_binary(topic) and topic != "" -> topic
      _ -> "unknown"
    end
  end

  defp dlq_topic(opts, topic) do
    case Keyword.get(opts, :dlq_topic) do
      dlq when is_binary(dlq) and dlq != "" -> dlq
      _ -> topic <> ".dlq"
    end
  end

  defp retry_max_ms(opts, poll_interval_ms) do
    max(Keyword.get(opts, :retry_max_ms, @default_retry_max_ms), poll_interval_ms)
  end
end
