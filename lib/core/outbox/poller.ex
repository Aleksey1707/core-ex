defmodule Core.Outbox.Poller do
  @moduledoc """
  Polling delivery worker: reserve → publish_many → save_results.

  Один sequential publisher: порядок в брокере = `order_by: created_at` reserve.
  При ошибке в середине батча — fail-stop (хвост `release` без attempts).

  После `:processed` — drain (`schedule(0)`). При `:retry` (хоть одна запись пачки не
  опубликована), idle или ошибке цикла — adaptive backoff от `idle_min_ms` до
  `poll_interval_ms`. `wake/1` будит цикл досрочно (после commit `append`); входящие
  `:wake` coalesce'ятся (`flush_wakes/0`).

  Поллер стартует только из `Core.Outbox.Supervisor`: его опции собирает дерево, а wake после
  вставки адресует поллеры по отметке дерева. Не найдя своего `:name` в отметке, `init/1`
  отказывает `ArgumentError`.

  Неизвестная опция, отсутствие обязательной и значение не той формы — `ArgumentError` в `init/1`.
  """

  use GenServer
  use Core.Options

  alias Core.Context
  alias Core.Error
  alias Core.Exc
  alias Core.Outbox
  alias Core.Outbox.Delivery
  alias Core.Outbox.Record
  alias Core.Outbox.Supervisor.Mark
  alias Core.Telemetry

  require Logger
  require Error

  @init_label "#{inspect(__MODULE__)}.init/1"

  @shutdown_ms 30_000

  @init_opts_schema [
    name: [
      type: {:custom, Core.Options.Type, :atom, []},
      type_doc: "`t:atom/0`",
      required: true,
      doc: "Имя процесса поллера; оно же `:id` в `child_spec/1`. MUST быть в отметке дерева очереди."
    ],
    repo: [
      type: {:custom, Core.Options.Type, :module, []},
      type_doc: "`t:module/0`",
      required: true,
      doc: "Репозиторий outbox (`Core.Outbox.Repo`): резерв пачки и запись результатов."
    ],
    delivery_module: [
      type: {:custom, Core.Options.Type, :module, []},
      type_doc: "`t:module/0`",
      required: true,
      doc: "Модуль доставки (`Core.Outbox.Delivery`)."
    ],
    delivery: [
      type: :any,
      type_doc: "`t:Core.Outbox.Delivery.t/0`",
      required: true,
      doc: "Доставка, которую принимает `delivery_module`."
    ],
    poll_interval_ms: [type: :pos_integer, required: true, doc: "Верхняя граница backoff опроса, мс."],
    idle_min_ms: [type: :pos_integer, required: true, doc: "Первая пауза backoff, мс."],
    batch_size: Core.Options.Type.prim_option(Core.Outbox.BatchSize, "Сколько записей резервирует цикл."),
    lock_duration: Core.Options.Type.prim_option(Core.Outbox.LockDuration, "Аренда зарезервированной пачки."),
    max_attempts: Core.Options.Type.prim_option(Core.Outbox.Attempts, "Попытки доставки записи до `:failed`."),
    topics: [
      type: {:custom, Core.Outbox, :topics_filter, []},
      type_doc: "`t:Core.Outbox.topics_filter/0`",
      default: :all,
      doc: "Топики записей, которые резервирует поллер."
    ],
    context_factory: [
      type: {:fun, 0},
      default: &Core.Context.new/0,
      doc: "Фабрика `Core.Context`; вызывается один раз в `init/1`."
    ],
    shutdown:
      Core.Helper.StartOpts.shutdown_option(@shutdown_ms, "`shutdown` в `child_spec/1`: запас на текущую пачку.")
  ]

  defstruct [
    :repo,
    :delivery_module,
    :delivery,
    :context,
    :poll_interval_ms,
    :idle_min_ms,
    :idle_ms,
    :timer_ref,
    :batch_size,
    :lock_duration,
    :max_attempts,
    :topics
  ]

  @typedoc """
  Исход одного цикла опроса.

  `:retry` — пачка обработана, но хоть одна запись не опубликована: следующий цикл
  идёт через backoff, иначе провалившаяся голова очереди повторяется без паузы.
  """
  @type cycle_result :: :processed | :retry | :idle | {:error, Error.t()}

  @type t :: %__MODULE__{
          repo: module(),
          delivery_module: module(),
          delivery: Delivery.t(),
          context: Context.t(),
          poll_interval_ms: pos_integer(),
          idle_min_ms: pos_integer(),
          idle_ms: pos_integer(),
          timer_ref: reference() | nil,
          batch_size: Outbox.BatchSize.t(),
          lock_duration: Outbox.LockDuration.t(),
          max_attempts: Outbox.Attempts.t(),
          topics: Outbox.topics_filter()
        }

  @doc "Запустить poller."
  @spec start_link(keyword()) :: GenServer.on_start()

  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc """
  Спецификация для Supervisor: `:id` = `:name`, иначе модуль.

  `:shutdown` (default #{@shutdown_ms} мс) — запас на текущую пачку: под `trap_exit`
  цикл дописывает результат доставки, и убивать его раньше нельзя.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()

  def child_spec(opts) when is_list(opts),
    do: Core.Helper.StartOpts.child_spec(__MODULE__, opts, @init_opts_schema)

  @doc """
  Разбудить poller (best-effort).

  `nil` или отсутствующий процесс → `:ok`.
  """
  @spec wake(GenServer.server() | nil) :: :ok

  def wake(nil), do: :ok

  def wake(server) do
    case GenServer.whereis(server) do
      nil ->
        :ok

      pid when is_pid(pid) ->
        send(pid, :wake)
        :ok
    end
  end

  @doc "Выполнить один цикл (для тестов)."
  @spec run_once(GenServer.server()) :: cycle_result()

  def run_once(server) do
    GenServer.call(server, :run_once, 60_000)
  end

  @opts_schema @init_opts_schema
  @doc false
  @spec init(keyword()) :: {:ok, t()}

  @impl true
  def init(opts) do
    # Цикл (reserve → publish → save_results) выполняется целиком в одном
    # handle_info: trap_exit даёт ему дописать результат, иначе пачка осталась бы
    # `:in_work` до истечения аренды.
    Process.flag(:trap_exit, true)
    idle_min_ms = Keyword.fetch!(opts, :idle_min_ms)

    state = %__MODULE__{
      repo: Keyword.fetch!(opts, :repo),
      delivery_module: Keyword.fetch!(opts, :delivery_module),
      delivery: Keyword.fetch!(opts, :delivery),
      context: Keyword.fetch!(opts, :context_factory).(),
      poll_interval_ms: Keyword.fetch!(opts, :poll_interval_ms),
      idle_min_ms: idle_min_ms,
      idle_ms: idle_min_ms,
      timer_ref: nil,
      batch_size: Keyword.fetch!(opts, :batch_size),
      lock_duration: Keyword.fetch!(opts, :lock_duration),
      max_attempts: Keyword.fetch!(opts, :max_attempts),
      topics: Keyword.fetch!(opts, :topics)
    }

    :ok = ensure_marked!(Keyword.fetch!(opts, :name))
    {:ok, schedule(state, idle_min_ms)}
  end

  @doc false
  @impl true
  def handle_call(:run_once, _from, state) do
    _ = flush_wakes()
    {:reply, process(state), state}
  end

  @doc false
  @impl true
  def handle_info(:tick, state) do
    _ = flush_wakes()
    state = cancel_timer(state)
    result = process(state)
    {:noreply, reschedule_after(state, result)}
  end

  # Backoff сбрасывает `reschedule_after/2` по исходу цикла, а не сам факт `wake`:
  # при недоступном брокере непрерывный `append` иначе держал бы интервал на `idle_min_ms`.
  def handle_info(:wake, state) do
    _ = flush_wakes()
    state = cancel_timer(state)
    result = process(state)
    {:noreply, reschedule_after(state, result)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @doc false
  @impl true
  def terminate(reason, _state) do
    Logger.info("Outbox poller остановлен: reason=#{inspect(reason)}")
    :ok
  end

  # ---

  defp ensure_marked!(name) do
    case Mark.member?(name) do
      true ->
        :ok

      false ->
        raise ArgumentError,
              "#{@init_label}: поллер #{inspect(name)} не из отметки дерева очереди — " <>
                "поллер стартует только из Core.Outbox.Supervisor"
    end
  end

  defp process(%__MODULE__{} = state) do
    start = System.monotonic_time()

    try do
      run_cycle(state, start)
    rescue
      e in [Exc] ->
        Logger.warning("Опрос outbox: #{Exception.message(e)}")
        emit_poller_cycle(start, :error, 0, 0, 0, 0)
        {:error, e.error}

      e ->
        Logger.error("Сбой цикла опроса outbox: #{Exception.format(:error, e, __STACKTRACE__)}")
        emit_poller_cycle(start, :error, 0, 0, 0, 0)

        {:error,
         Error.app(
           code: :cycle_failed,
           ns: :outbox,
           message: "Сбой цикла outbox poller",
           detail: e
         )}
    catch
      # За publish стоит `GenServer.call` к writer'у: его падение или недоступность
      # приходят как exit, а не как `{:error, _}`. Без этой ветки цикл роняет поллер,
      # а `:rest_for_one` — всё поддерево outbox; записи остаются `:in_work` до аренды.
      :exit, reason ->
        Logger.error("Сбой цикла опроса outbox: exit reason=#{inspect(reason)}")
        emit_poller_cycle(start, :error, 0, 0, 0, 0)

        {:error,
         Error.app(
           code: :cycle_exit,
           ns: :outbox,
           message: "Цикл outbox poller прерван exit",
           detail: reason
         )}
    end
  end

  defp run_cycle(%__MODULE__{context: context} = state, start) do
    records =
      state.repo.fetch_and_reserve(
        state.batch_size,
        state.lock_duration,
        state.topics,
        context
      )

    case records do
      [] ->
        emit_poller_cycle(start, :idle, 0, 0, 0, 0)
        :idle

      records when is_list(records) ->
        deliver_reserved(records, state, start)
    end
  end

  # Сбой между резервацией и записью результата оставил бы пачку `:in_work` до
  # истечения аренды: снимаем её сразу и отдаём ошибку выше — в общий rescue цикла.
  defp deliver_reserved(records, %__MODULE__{} = state, start) do
    deliver_and_save(records, state, start)
  rescue
    e ->
      release_reserved(records, state)
      reraise e, __STACKTRACE__
  catch
    :exit, reason ->
      release_reserved(records, state)
      exit(reason)
  end

  defp deliver_and_save(records, %__MODULE__{context: context} = state, start) do
    now = DateTime.utc_now()
    at = Outbox.UpdatedAt.new!(now)
    published_at = Outbox.PublishedAt.new!(now)
    results = deliver_batch(records, state, published_at, at)
    {published, retry, failed} = outcome_counts(results)
    log_batch_summary(length(results), published, retry, failed)
    :ok = state.repo.save_results(results, context)
    outcome = cycle_outcome(retry, failed)
    emit_poller_cycle(start, outcome, length(results), published, retry, failed)
    outcome
  end

  # Непроуспевшая запись возвращается в `:new` и по `order_by: created_at` попадает в
  # следующую же пачку. Без отдельного исхода цикл планировался бы как `:processed` —
  # `schedule(0)`, и недоступный брокер сжигал бы `max_attempts` за миллисекунды.
  defp cycle_outcome(0, 0), do: :processed
  defp cycle_outcome(_retry, _failed), do: :retry

  defp release_reserved(records, %__MODULE__{context: context} = state) do
    state.repo.release(records, context)
  rescue
    e ->
      Logger.error("Outbox: не удалось снять аренду после сбоя цикла: #{Exception.message(e)}")
      :ok
  catch
    :exit, reason ->
      Logger.error("Outbox: не удалось снять аренду после сбоя цикла: exit reason=#{inspect(reason)}")

      :ok
  end

  defp deliver_batch(records, %__MODULE__{} = state, published_at, at) do
    case state.delivery_module.publish_many(state.delivery, records) do
      :ok ->
        Enum.map(records, &mark_published_one(&1, published_at, at))

      {:error, index, %Error{} = error}
      when is_integer(index) and index >= 0 and index < length(records) ->
        apply_fail_stop(records, index, error, state.max_attempts, published_at, at)

      {:error, index, %Error{} = error} ->
        log_bad_index(state.delivery_module, index, length(records), error)
        apply_fail_stop(records, 0, error, state.max_attempts, published_at, at)
    end
  end

  # `Delivery` и стоящий за ним `Mq.Writer` — точка расширения потребителя (README):
  # чужая реализация может вернуть индекс вне пачки. Досчитать такую пачку до конца
  # нельзя — записи ушли бы в `published`, не побывав в брокере, без строки в логе.
  # Трактуем как провал с нулевого индекса: опубликованным не считается ничего.
  defp log_bad_index(module, index, size, %Error{} = error) do
    Logger.error(
      "Outbox: delivery вернул индекс вне пачки, пачка считается непроуспевшей: " <>
        "delivery=#{inspect(module)} index=#{inspect(index)} size=#{size} " <>
        "ошибка=#{error.message}"
    )
  end

  # `index` в границах пачки гарантирует вызывающий, пачка непуста (`run_cycle/2`):
  # промах match'а уйдёт в общий rescue цикла — с backoff и снятием аренды.
  defp apply_fail_stop(records, index, error, max_attempts, published_at, at) do
    {before, [failed | tail]} = Enum.split(records, index)

    published = Enum.map(before, &mark_published_one(&1, published_at, at))
    failed_rec = record_delivery_failure(failed, error, max_attempts, at)
    log_delivery_failure(failed_rec, error, max_attempts)
    emit_delivery(failed_rec)
    released = Enum.map(tail, &Record.release(&1, at))
    published ++ [failed_rec | released]
  end

  defp mark_published_one(record, published_at, at) do
    published = Record.mark_published(record, published_at, at)

    Logger.debug(
      "Outbox опубликован: id=#{Outbox.ID.format(record.id, :hex)} " <>
        "topic=#{Outbox.Topic.value(record.topic)} " <>
        "name=#{Outbox.Name.value(record.name)} " <>
        "attempt=#{Outbox.Attempts.value(record.attempts)}"
    )

    emit_delivery(published)
    published
  end

  defp record_delivery_failure(record, error, max_attempts, at) do
    with {:ok, message} <- Outbox.ErrorMessage.create(error.message),
         {:ok, failed} <- Record.record_failure(record, message, max_attempts, at) do
      failed
    else
      # Вернуть исходную запись нельзя: она осталась бы `:in_work` с непросроченной
      # арендой — ни повтора, ни метрики, ни следа в логе до истечения lock_duration.
      {:error, reason} ->
        Logger.error(
          "Outbox: не удалось записать ошибку доставки, запись возвращена в очередь: " <>
            "id=#{Outbox.ID.format(record.id, :hex)} причина=#{inspect(reason)}"
        )

        Record.release(record, at)
    end
  end

  defp log_delivery_failure(%Record{status: :failed} = record, error, max_attempts) do
    Logger.error(
      "Outbox окончательно провален: id=#{Outbox.ID.format(record.id, :hex)} " <>
        "attempt=#{Outbox.Attempts.value(record.attempts)}/#{Outbox.Attempts.value(max_attempts)} " <>
        "ошибка=#{error.message}"
    )
  end

  defp log_delivery_failure(%Record{} = record, error, max_attempts) do
    Logger.warning(
      "Ошибка доставки outbox, будет повтор: id=#{Outbox.ID.format(record.id, :hex)} " <>
        "attempt=#{Outbox.Attempts.value(record.attempts)}/#{Outbox.Attempts.value(max_attempts)} " <>
        "ошибка=#{error.message}"
    )
  end

  defp outcome_counts(results) do
    {
      Enum.count(results, &(&1.status == :published)),
      Enum.count(results, &(&1.status == :new)),
      Enum.count(results, &(&1.status == :failed))
    }
  end

  defp log_batch_summary(size, published, retry, failed) do
    Logger.debug("Опрос outbox: пакет size=#{size} опубликовано=#{published} повтор=#{retry} провалено=#{failed}")
  end

  defp emit_poller_cycle(start, result, batch_size, published, retry, failed) do
    :telemetry.execute(
      Telemetry.event([:outbox, :poller, :cycle]),
      %{
        duration: System.monotonic_time() - start,
        batch_size: batch_size,
        published: published,
        retry: retry,
        failed: failed
      },
      %{result: result}
    )
  end

  defp emit_delivery(%Record{status: :published} = record),
    do: do_emit_delivery(:published, record)

  defp emit_delivery(%Record{status: :failed} = record),
    do: do_emit_delivery(:failed, record)

  defp emit_delivery(%Record{status: :new} = record),
    do: do_emit_delivery(:retry, record)

  defp do_emit_delivery(outcome, %Record{} = record) do
    :telemetry.execute(
      Telemetry.event([:outbox, :delivery]),
      %{count: 1},
      %{outcome: outcome, topic: Outbox.Topic.value(record.topic)}
    )
  end

  defp reschedule_after(state, result) do
    had_wake = flush_wakes()

    case {result, had_wake} do
      # Провал доставки уводит в backoff и при пришедшем `:wake`: новые записи не делают
      # публикуемой ту голову очереди, на которой цикл только что споткнулся.
      {:retry, _} ->
        schedule_backoff(state)

      {:processed, _} ->
        schedule(%{state | idle_ms: state.idle_min_ms}, 0)

      {:idle, true} ->
        schedule(%{state | idle_ms: state.idle_min_ms}, 0)

      {{:error, _}, true} ->
        schedule(%{state | idle_ms: state.idle_min_ms}, 0)

      {:idle, false} ->
        schedule_backoff(state)

      {{:error, _}, false} ->
        schedule_backoff(state)
    end
  end

  defp flush_wakes do
    receive do
      :wake ->
        _ = flush_wakes()
        true
    after
      0 -> false
    end
  end

  defp schedule_backoff(%__MODULE__{idle_ms: idle_ms, poll_interval_ms: cap} = state) do
    next = min(idle_ms * 2, cap)
    # First idle after init/processed uses current idle_ms (idle_min); then doubles for next.
    state = %{state | idle_ms: next}
    schedule(state, idle_ms)
  end

  defp schedule(%__MODULE__{} = state, ms) do
    state = cancel_timer(state)
    ref = Process.send_after(self(), :tick, ms)
    %{state | timer_ref: ref}
  end

  defp cancel_timer(%__MODULE__{timer_ref: nil} = state), do: state

  defp cancel_timer(%__MODULE__{timer_ref: ref} = state) do
    _ = Process.cancel_timer(ref)
    %{state | timer_ref: nil}
  end
end
