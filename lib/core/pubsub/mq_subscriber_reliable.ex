defmodule Core.PubSub.MqSubscriberReliable do
  @moduledoc """
  `PubSub.Subscriber` поверх `Mq.ReaderReliable`.

  Успех / `{:skip, _}` → `commit`. Ошибка handler/decode → без commit (redelivery).
  Цикл не останавливается на ошибках handler. Необработанное исключение внутри
  `on_message`/`from_message` перехватывается и превращается в `{:error, %Error{}}`
  (без commit, redelivery) — не роняет подписчик в crash-loop на «ядовитом» сообщении.

  Фильтр `filter` решает по сырому `Mq.Message` (заголовки, ключ, топик) до `from_message`:
  отвергнутое сообщение коммитится без декодирования тела, span'а не открывает и даёт исход
  цикла `:filtered` — отдельный от `{:skip, _}` обработчика. Исключение или не-boolean из
  фильтра — ошибка обработки: без commit, с тем же счётом попыток и выходом в DLQ.

  Повторы одного и того же сообщения считаются: интервал растёт от `poll_interval_ms`
  до `retry_max_ms`, а после `max_attempts` неудач сообщение уходит в DLQ-топик
  (`dlq_topic`, по умолчанию `"<topic>.dlq"`) и коммитится — иначе оно блокировало бы
  топик навсегда. Без настроенного `dlq_writer` выброса не происходит: подписчик
  продолжает повторы на `retry_max_ms` и пишет `error` в лог. В DLQ уходит сырое сообщение с
  его ключом, телом и позицией источника (`Message.position`); DLQ в Postgres — `Core.Mq.Dlq`.

  Отказ без повторов — `{:reject, %Error{}}` из `on_message` или `from_message`
  (`Core.PubSub`): сообщение, которое не обработать никогда, уходит в DLQ сразу, без
  `max_attempts` попыток, и коммитится. Причина выброса — заголовок `x-dlq-reason`
  (`rejected` / `exhausted`), метка `reason` события `[:mq, :subscriber, :dlq]` и атрибут
  `core.pubsub.dlq_reason` span'а. Без `dlq_writer` отказ ведёт себя как исчерпание попыток
  без DLQ: `error` в лог, без commit, повторы с растущим интервалом.

  После `:processed` / `:filtered` / `:dlq` — немедленный следующий tick (`schedule(0)`, drain).
  После `:error` — текущий backoff. После `:idle` — `poll_interval_ms`, если reader не принимает
  заявку на готовность (`Core.Mq.ReaderReliable.notify_when_ready/2`). Reader с заявкой в простое
  не опрашивается: подписчик оставляет ему заявку и читает дальше по `{:mq_ready, ref}`; от
  `poll_interval_ms` у него остаётся только начальная пауза повтора. Страховочного опроса нет:
  заявку reader проверяет по своему буферу в своём же процессе, и разминуться с сообщением она не
  может, а потерять её может только упавший reader — за ним подписчик следит монитором и после
  `:DOWN` уходит в backoff. Поэтому handle такого reader'а — процесс (`GenServer.whereis/1`
  находит pid). Не принятая заявка — тоже backoff.

  Первый `:idle` после работы уводит процесс в `:hibernate`: полная сборка освобождает кучу,
  раздутую пачкой сообщений. На холостом опросе мусора почти нет, и без этого куча держала бы
  пиковый размер до рестарта. Повторный `:idle` процесс не усыпляет: полная сборка на каждый
  опрос стоила бы больше, чем экономит. Работой считаются только прочитанные сообщения
  (`:processed` / `:filtered` / `:dlq`); старт подписки работой не считается. `:error` счёт не
  меняет: `:idle` после ошибки усыпит процесс, только если до неё были прочитанные сообщения.
  Цикл `run_once/1` считается так же.

  Обработка сообщения идёт в span'е `"process <topic>"` (`kind: :consumer`),
  родитель которого извлекается из заголовков сообщения (`Core.Otel.Messaging`):
  трейс команды, записавшей событие в outbox, продолжается здесь, а не начинается
  заново.
  """

  @behaviour Core.PubSub.Subscriber

  use GenServer

  alias Core.Context
  alias Core.Error
  alias Core.Helper.StartOpts
  alias Core.Mq
  alias Core.Mq.Message
  alias Core.Otel
  alias Core.PubSub
  alias Core.PubSub.MqSubscriberReliable.Step
  alias Core.Result
  alias Core.Telemetry

  require Logger
  require Error

  @attr_dlq_topic "core.pubsub.dlq_topic"
  @attr_dlq_reason "core.pubsub.dlq_reason"

  @label "PubSub.MqSubscriberReliable"

  @keys ~w(
    reader_module reader filter from_message on_message context_factory poll_interval_ms retry_max_ms
    max_attempts dlq_writer dlq_handle dlq_topic topic subscribe subscribe_data name shutdown
  )a

  @shutdown_ms 30_000
  @call_timeout 5_000
  @fallback_poll_interval_ms 100
  @default_max_attempts 5
  @default_retry_max_ms 30_000
  @worked ~w(processed filtered dlq)a

  defstruct [
    :reader_module,
    :reader,
    :step,
    :poll_interval_ms,
    :retry_max_ms,
    :retry_ms,
    :max_attempts,
    :dlq_writer,
    :dlq_handle,
    :dlq_topic,
    :topic,
    :timer_ref,
    :pending_raw,
    ready_requests?: false,
    ready_request: nil,
    attempts: 0,
    subscribed?: false,
    hibernated?: true
  ]

  @type domain_message :: term()
  @type subscriber_data :: term()

  @type filter :: (Message.t() -> boolean())

  @type from_message :: (Message.t() -> PubSub.decode_result(domain_message()))

  @type on_message ::
          (domain_message(), subscriber_data(), Context.t() -> PubSub.handler_result())

  @type t :: GenServer.server()

  @typedoc "Исход одного цикла чтения."
  @type cycle_result :: :processed | :filtered | :dlq | :idle | :error | :not_subscribed

  @doc """
  Спецификация ребёнка супервизора.

  `:shutdown` (default #{@shutdown_ms} мс) — запас на единицу работы: обработка
  сообщения и commit offset идут целиком в одном колбэке под `trap_exit`, и остановка
  на середине переотправила бы уже обработанное сообщение.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()

  def child_spec(opts) when is_list(opts) do
    %{
      id: StartOpts.name!(@label, opts, :name) || __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      shutdown: StartOpts.shutdown!(@label, opts, :shutdown, @shutdown_ms)
    }
  end

  @doc """
  Запустить reliable subscriber.

  Opts: `:reader_module`, `:reader`, `:from_message`, `:on_message`,
  опционально `:filter` (предикат по сырому сообщению до `from_message`, по умолчанию
  пропускает всё), `:context_factory` (вызывается на каждое сообщение), `:poll_interval_ms`
  (по умолчанию — `default_poll_interval_ms/0` reader'а, если он его объявил, иначе 100),
  `:topic` (string для метрик и имени DLQ), `:name`.

  DLQ: `:dlq_writer` (модуль `Mq.Writer`), `:dlq_handle` (его handle — обязателен при
  `:dlq_writer` и без него не задаётся), `:dlq_topic` (по умолчанию `"<topic>.dlq"`),
  `:max_attempts`, `:retry_max_ms`.

  Подписка при старте: `:subscribe` (по умолчанию `false`) — процесс подписан сразу после
  `init/1`, и `subscribe/3` снаружи не нужен (повторный вызов вернёт `:already_subscribed`);
  `:subscribe_data` (по умолчанию `nil`) — данные подписки для `on_message`, как `data` у
  `subscribe/3`, задаются только вместе с `subscribe: true`.

  Неизвестная опция, отсутствие обязательной и значение не той формы — `ArgumentError` при
  старте (`Core.Helper.StartOpts`).
  """
  @spec start_link(keyword()) :: GenServer.on_start()

  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc "Подписаться на чтение сообщений."
  @spec subscribe(t(), subscriber_data(), Context.t()) :: Result.unit()

  @impl true
  def subscribe(server, data, %Context{}) do
    GenServer.call(server, {:subscribe, data}, @call_timeout)
  end

  @doc "Отписаться от чтения."
  @spec unsubscribe(t(), Context.t()) :: Result.unit()

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
    StartOpts.keys!(@label, opts, @keys)
    reader_module = StartOpts.module!(@label, opts, :reader_module)
    poll_interval_ms = StartOpts.pos_integer!(@label, opts, :poll_interval_ms, default_poll_interval_ms(reader_module))
    step = Step.new!(@label, opts)
    dlq_writer = StartOpts.module!(@label, opts, :dlq_writer, nil)

    state = %__MODULE__{
      reader_module: reader_module,
      reader: StartOpts.term!(@label, opts, :reader),
      ready_requests?: exports?(reader_module, :notify_when_ready, 2),
      step: step,
      poll_interval_ms: poll_interval_ms,
      retry_max_ms: retry_max_ms(opts, poll_interval_ms),
      retry_ms: poll_interval_ms,
      max_attempts: StartOpts.pos_integer!(@label, opts, :max_attempts, @default_max_attempts),
      dlq_writer: dlq_writer,
      dlq_handle: dlq_handle!(opts, dlq_writer),
      dlq_topic: StartOpts.binary!(@label, opts, :dlq_topic, step.topic <> ".dlq"),
      topic: step.topic,
      timer_ref: nil,
      pending_raw: nil,
      attempts: 0,
      subscribed?: false
    }

    {:ok, subscribe_on_start!(state, opts)}
  end

  @doc false
  @impl true
  def handle_call({:subscribe, _data}, _from, %__MODULE__{subscribed?: true} = state) do
    error =
      Error.app(code: :already_subscribed, ns: :pubsub, message: "Уже подписан")

    {:reply, {:error, error}, state}
  end

  def handle_call({:subscribe, data}, _from, state) do
    {:reply, :ok, mark_subscribed(state, data)}
  end

  def handle_call(:unsubscribe, _from, state) do
    state = drop_ready(cancel_timer(state))
    {:reply, :ok, %{state | subscribed?: false, step: %{state.step | data: nil}, pending_raw: nil, attempts: 0}}
  end

  def handle_call(:run_once, _from, %__MODULE__{subscribed?: false} = state) do
    emit_cycle(state, :not_subscribed)
    {:reply, :not_subscribed, state}
  end

  def handle_call(:run_once, _from, state) do
    {result, state} = consume_once(state)
    emit_cycle(state, result)
    {state, sleep} = sleep_after(state, result)
    {:reply, result, state, sleep}
  end

  @doc false
  @impl true
  def handle_info(:tick, %__MODULE__{subscribed?: false} = state) do
    {:noreply, state}
  end

  def handle_info(:tick, state) do
    state = drop_ready(cancel_timer(state))
    {result, state} = consume_once(state)
    emit_cycle(state, result)

    {state, sleep} =
      state
      |> reschedule(result)
      |> sleep_after(result)

    {:noreply, state, sleep}
  end

  def handle_info({:mq_ready, ref}, %__MODULE__{ready_request: {ref, _monitor}} = state) do
    handle_info(:tick, state)
  end

  def handle_info({:DOWN, monitor, :process, _pid, reason}, %__MODULE__{ready_request: {_ref, monitor}} = state) do
    Logger.warning("pubsub reliable: reader упал в ожидании готовности: topic=#{state.topic} reason=#{inspect(reason)}")
    {:noreply, reschedule(%{state | ready_request: nil}, :error)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # ---

  defp consume_once(state) do
    case safe_get(state) do
      :empty ->
        {:idle, state}

      {:ok, raw} ->
        state = count_attempt(state, raw)
        Step.run(raw, state.step, state.attempts, &settle(state, raw, &1))

      {:error, %Error{} = error} ->
        Logger.warning("pubsub reliable get: #{error.message}")
        {:error, state}
    end
  end

  # За reader'ом стоит процесс: недоступный или упавший приходит `exit` вызова, а не
  # `{:error, _}` (`Core.Mq.ReaderReliable`). Подписчик от этого не падает — цикл уходит
  # в backoff и повторяет чтение, когда reader поднимет супервизор.
  defp safe_get(state) do
    state.reader_module.get(state.reader, 0)
  catch
    :exit, reason -> {:error, reader_unavailable_error(reason)}
  end

  defp reader_unavailable_error(reason) do
    Error.app(
      code: :reader_unavailable,
      ns: :pubsub,
      message: "MQ reader недоступен",
      detail: reason
    )
  end

  # Тот же raw, что и на прошлом цикле, — очередная попытка: reliable-reader отдаёт
  # неподтверждённое сообщение повторно, пока не пришёл commit.
  defp count_attempt(%__MODULE__{pending_raw: raw} = state, raw) do
    %{state | attempts: state.attempts + 1}
  end

  defp count_attempt(state, raw) do
    %{state | pending_raw: raw, attempts: 1, retry_ms: state.poll_interval_ms}
  end

  # Исход шага разбирается внутри его span'а обработки (у исхода фильтра span'а нет): уход в DLQ
  # отмечается на этом span'е.
  defp settle(state, _raw, :processed), do: succeed(state)

  defp settle(state, _raw, :filtered) do
    commit(state)
    {:filtered, clear_pending(state)}
  end

  defp settle(state, raw, {:retry, error}), do: fail_attempt(state, raw, error)

  defp settle(state, raw, {:reject, error}), do: reject(state, raw, error)

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

  defp exhausted(%__MODULE__{} = state, raw, error), do: to_dlq(state, raw, error, :exhausted)

  defp reject(%__MODULE__{dlq_writer: nil} = state, _raw, error) do
    Logger.error(
      "pubsub reliable: сообщение отклонено, DLQ не настроен, повторы продолжаются: " <>
        "topic=#{state.topic} ошибка=#{Error.format_chain(error)}"
    )

    {:error, state}
  end

  defp reject(%__MODULE__{} = state, raw, error), do: to_dlq(state, raw, error, :rejected)

  defp to_dlq(%__MODULE__{} = state, raw, error, reason) do
    case publish_to_dlq(state, raw, error, reason) do
      :ok ->
        commit(state)
        log_dlq(state, error, reason)
        emit_dlq(state, reason)
        Otel.set_attributes(%{@attr_dlq_topic => state.dlq_topic, @attr_dlq_reason => Atom.to_string(reason)})
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
  defp publish_to_dlq(%__MODULE__{} = state, %Message{} = raw, error, reason) do
    with {:ok, topic} <- Mq.Topic.new(state.dlq_topic),
         {:ok, message} <-
           Message.new(topic, dlq_headers(state, raw, error, reason), raw.body, raw.key, raw.position) do
      state.dlq_writer.put(state.dlq_handle, message)
    end
  rescue
    exception -> {:error, dlq_publish_error(exception)}
  catch
    :exit, reason -> {:error, dlq_publish_error(reason)}
  end

  defp dlq_publish_error(detail) do
    Error.app(
      code: :dlq_publish_failed,
      ns: :pubsub,
      message: "Не удалось опубликовать сообщение в DLQ",
      detail: detail
    )
  end

  defp dlq_headers(%__MODULE__{} = state, %Message{headers: headers}, error, reason) do
    Map.merge(headers, %{
      "x-dlq-source-topic" => state.topic,
      "x-dlq-attempts" => Integer.to_string(state.attempts),
      "x-dlq-reason" => Atom.to_string(reason),
      "x-dlq-error" => String.slice(Error.format_chain(error), 0, 1000)
    })
  end

  defp log_dlq(%__MODULE__{} = state, error, :rejected) do
    Logger.error(
      "pubsub reliable: сообщение отклонено и отправлено в DLQ: " <>
        "topic=#{state.topic} dlq=#{state.dlq_topic} ошибка=#{Error.format_chain(error)}"
    )
  end

  defp log_dlq(%__MODULE__{} = state, error, :exhausted) do
    Logger.error(
      "pubsub reliable: сообщение отправлено в DLQ после #{state.attempts} попыток: " <>
        "topic=#{state.topic} dlq=#{state.dlq_topic} ошибка=#{Error.format_chain(error)}"
    )
  end

  defp clear_pending(state) do
    %{state | pending_raw: nil, attempts: 0, retry_ms: state.poll_interval_ms}
  end

  defp commit(state) do
    case safe_commit(state) do
      :ok ->
        :ok

      {:error, %Error{} = error} ->
        Logger.warning("pubsub reliable commit: #{error.message}")
    end
  end

  defp safe_commit(state) do
    state.reader_module.commit(state.reader)
  catch
    :exit, reason -> {:error, reader_unavailable_error(reason)}
  end

  defp mark_subscribed(state, data) do
    state = %{state | step: %{state.step | data: data}, subscribed?: true, hibernated?: true}
    schedule(state, state.poll_interval_ms)
  end

  defp reschedule(state, result) when result in @worked do
    schedule(state, 0)
  end

  defp reschedule(state, :error) do
    next = min(state.retry_ms * 2, state.retry_max_ms)
    schedule(%{state | retry_ms: next}, state.retry_ms)
  end

  defp reschedule(%__MODULE__{ready_requests?: true} = state, :idle), do: await_ready(state)

  defp reschedule(state, _other) do
    schedule(state, state.poll_interval_ms)
  end

  # Монитор ставится до заявки: reader, упавший между ними, приходит `:DOWN`, а не молчанием.
  defp await_ready(state) do
    with pid when is_pid(pid) <- GenServer.whereis(state.reader),
         monitor = Process.monitor(pid),
         {:ok, ref} <- safe_notify(state, monitor) do
      %{state | ready_request: {ref, monitor}}
    else
      other ->
        Logger.warning(
          "pubsub reliable: заявка на готовность не принята: topic=#{state.topic} reason=#{inspect(other)}"
        )

        reschedule(state, :error)
    end
  end

  defp safe_notify(state, monitor) do
    case state.reader_module.notify_when_ready(state.reader, self()) do
      {:ok, ref} ->
        {:ok, ref}

      {:error, %Error{}} = error ->
        Process.demonitor(monitor, [:flush])
        error
    end
  catch
    :exit, reason ->
      Process.demonitor(monitor, [:flush])
      {:error, reader_unavailable_error(reason)}
  end

  defp drop_ready(%__MODULE__{ready_request: nil} = state), do: state

  defp drop_ready(%__MODULE__{ready_request: {_ref, monitor}} = state) do
    Process.demonitor(monitor, [:flush])
    %{state | ready_request: nil}
  end

  defp sleep_after(%__MODULE__{hibernated?: false} = state, :idle), do: {%{state | hibernated?: true}, :hibernate}
  defp sleep_after(%__MODULE__{} = state, result) when result in @worked, do: {%{state | hibernated?: false}, :infinity}
  defp sleep_after(%__MODULE__{} = state, _result), do: {state, :infinity}

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

  defp emit_dlq(state, reason) do
    :telemetry.execute(
      Telemetry.event([:mq, :subscriber, :dlq]),
      %{count: 1},
      %{topic: state.topic, dlq_topic: state.dlq_topic, reason: reason}
    )
  end

  defp default_poll_interval_ms(reader_module) do
    if exports?(reader_module, :default_poll_interval_ms, 0),
      do: reader_module.default_poll_interval_ms(),
      else: @fallback_poll_interval_ms
  end

  defp exports?(module, fun, arity), do: Code.ensure_loaded?(module) and function_exported?(module, fun, arity)

  defp retry_max_ms(opts, poll_interval_ms) do
    max(StartOpts.pos_integer!(@label, opts, :retry_max_ms, @default_retry_max_ms), poll_interval_ms)
  end

  defp dlq_handle!(opts, nil) do
    case Keyword.get(opts, :dlq_handle) do
      nil -> nil
      handle -> StartOpts.raise_invalid!(@label, :dlq_handle, "её отсутствие без :dlq_writer", handle)
    end
  end

  defp dlq_handle!(opts, _dlq_writer), do: StartOpts.term!(@label, opts, :dlq_handle)

  defp subscribe_on_start!(state, opts) do
    case {StartOpts.boolean!(@label, opts, :subscribe, false), Keyword.fetch(opts, :subscribe_data)} do
      {true, {:ok, data}} ->
        mark_subscribed(state, data)

      {true, :error} ->
        mark_subscribed(state, nil)

      {false, :error} ->
        state

      {false, {:ok, data}} ->
        StartOpts.raise_invalid!(@label, :subscribe_data, "её отсутствие без subscribe: true", data)
    end
  end
end
