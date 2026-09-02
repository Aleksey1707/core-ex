defmodule Core.Outbox.Poller do
  @moduledoc """
  Polling delivery worker: reserve → publish_many → save_results.

  Один sequential publisher: порядок в брокере = `order_by: created_at` reserve.
  При ошибке в середине батча — fail-stop (хвост `release` без attempts).

  После `:processed` — drain (`schedule(0)`). При idle/error — adaptive backoff
  от `idle_min_ms` до `poll_interval_ms`. `wake/1` будит цикл досрочно
  (после commit `append`); входящие `:wake` coalesce'ятся (`flush_wakes/0`).

  Обязательные opts: `:repo`, `:delivery`, `:poll_interval_ms`, `:idle_min_ms`,
  `:batch_size`, `:lock_duration`, `:max_attempts`.
  Опционально: `:topics` (`Outbox.topics_filter()`, default `:all`),
  `:context_factory` (`()-> Context.t()`, вызывается один раз в `init`,
  default `Context.new/0`), `:name`.
  """

  use GenServer

  alias Core.Context
  alias Core.Error
  alias Core.Exc
  alias Core.Outbox
  alias Core.Outbox.Delivery
  alias Core.Outbox.Record
  alias Core.Telemetry

  require Logger
  require Error

  @shutdown_ms 30_000

  defstruct [
    :repo,
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

  @type t :: %__MODULE__{
          repo: module(),
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

  def child_spec(opts) when is_list(opts) do
    id =
      case Keyword.get(opts, :name) do
        nil -> __MODULE__
        name -> name
      end

    %{
      id: id,
      start: {__MODULE__, :start_link, [opts]},
      shutdown: Keyword.get(opts, :shutdown, @shutdown_ms)
    }
  end

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
  @spec run_once(GenServer.server()) :: :processed | :idle | {:error, Error.t()}

  def run_once(server) do
    GenServer.call(server, :run_once, 60_000)
  end

  @doc false
  @impl true
  def init(opts) do
    # Цикл (reserve → publish → save_results) выполняется целиком в одном
    # handle_info: trap_exit даёт ему дописать результат, иначе пачка осталась бы
    # `:in_work` до истечения аренды.
    Process.flag(:trap_exit, true)
    idle_min_ms = Keyword.fetch!(opts, :idle_min_ms)

    state = %__MODULE__{
      repo: Keyword.fetch!(opts, :repo),
      delivery: Keyword.fetch!(opts, :delivery),
      context: Keyword.get(opts, :context_factory, &Context.new/0).(),
      poll_interval_ms: Keyword.fetch!(opts, :poll_interval_ms),
      idle_min_ms: idle_min_ms,
      idle_ms: idle_min_ms,
      timer_ref: nil,
      batch_size: Keyword.fetch!(opts, :batch_size),
      lock_duration: Keyword.fetch!(opts, :lock_duration),
      max_attempts: Keyword.fetch!(opts, :max_attempts),
      topics: Keyword.get(opts, :topics, :all)
    }

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

  def handle_info(:wake, state) do
    _ = flush_wakes()

    state =
      state
      |> cancel_timer()
      |> Map.put(:idle_ms, state.idle_min_ms)

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
         Error.app(__MODULE__,
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
         Error.app(__MODULE__,
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
    at = Outbox.UpdatedAt.now!()
    published_at = Outbox.PublishedAt.now!()
    results = deliver_batch(records, state.delivery, state.max_attempts, published_at, at)
    {published, retry, failed} = outcome_counts(results)
    log_batch_summary(length(results), published, retry, failed)
    :ok = state.repo.save_results(results, context)
    emit_poller_cycle(start, :processed, length(results), published, retry, failed)
    :processed
  end

  defp release_reserved(records, %__MODULE__{context: context} = state) do
    state.repo.release(records, context)
  rescue
    e ->
      Logger.error("Outbox: не удалось снять аренду после сбоя цикла: #{Exception.message(e)}")
      :ok
  catch
    :exit, reason ->
      Logger.error(
        "Outbox: не удалось снять аренду после сбоя цикла: exit reason=#{inspect(reason)}"
      )

      :ok
  end

  defp deliver_batch(records, delivery, max_attempts, published_at, at) do
    delivery_mod = delivery.__struct__

    case delivery_mod.publish_many(delivery, records) do
      :ok ->
        Enum.map(records, &mark_published_one(&1, published_at, at))

      {:error, index, %Error{} = error} when is_integer(index) and index >= 0 ->
        apply_fail_stop(records, index, error, max_attempts, published_at, at)
    end
  end

  defp apply_fail_stop(records, index, error, max_attempts, published_at, at) do
    {before, rest} = Enum.split(records, index)

    case rest do
      [failed | tail] ->
        published = Enum.map(before, &mark_published_one(&1, published_at, at))
        failed_rec = record_delivery_failure(failed, error, max_attempts, at)
        log_delivery_failure(failed_rec, error, max_attempts)
        emit_delivery(failed_rec)
        released = Enum.map(tail, &Record.release(&1, at))
        published ++ [failed_rec | released]

      [] ->
        Enum.map(before, &mark_published_one(&1, published_at, at))
    end
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
    Logger.debug(
      "Опрос outbox: пакет size=#{size} опубликовано=#{published} повтор=#{retry} провалено=#{failed}"
    )
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
