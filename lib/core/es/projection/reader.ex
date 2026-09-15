defmodule Core.Es.Projection.Reader do
  @moduledoc """
  Читатель проекции — процесс дерева `Core.Es.Projection.Supervisor`, по одному на проекцию под
  именем её модуля: гоняет пачки проекции (`Core.Es.Projection`, «Пачка») по таймеру и по `wake`
  после commit `Core.Es.Store.append/5`.

  В `init/1` читатель регистрируется в `Core.Es.Projection.Registry` под типами агрегатов из
  `events:`; запросов в `init/1` нет, первый тик — через `idle_min_ms`. Опции проверяет и
  перечисляет супервизор.

  ## Цикл

  Исход пачки → следующий тик:

  - `:processed` (события или старт с начала истории) — сразу, backoff'ы сброшены;
  - `:idle`, `:locked` — от `idle_min_ms` с удвоением до `poll_interval_ms`; `wake` в ожидании —
    цикл сразу без сброса счётчика;
  - `:retry` (отказ пачки, исключение, exit, throw) — от `retry_min_ms` с удвоением до
    `retry_max_ms`, `wake` не ускоряет;
  - `:outdated` (чекпоинт новее `version:`) — через `poll_interval_ms`, `wake` не ускоряет.

  `wake` вычерпываются в начале и в конце цикла, лишние `:tick` — в начале; `wake`, пришедший за
  время цикла после `:idle` / `:locked`, — следующий цикл сразу. Серию повторов заканчивает любой
  исход, кроме `:retry` и `:locked` (пачку держит другая нода): задержка повтора и номер попытки — с
  начала. Решение о тике — `next_tick/3`.

  На `:retry` процесс жив и не рестартует, чекпоинт стоит, событие не пропускается: `warning` на
  каждую попытку с `projection=`, `position=` (чекпоинт до пачки), `event_id=` (событие отказа) и
  `attempt=`; попытка, начало серии и код ошибки — в state. Переход в `:outdated` — `warning` один
  раз.

  Пачка идёт целиком в одном `handle_info/2`: читатель ставит `trap_exit`, остановка супервизором
  ждёт конца пачки в пределах `shutdown:`, `terminate/2` только логирует.

  ## Telemetry

  `[:es, :projection, :cycle]` (`Core.Telemetry.event/1`) на каждый цикл, включая `:idle` и
  `:locked`:

  - измерения: `duration` (native), `events` — прочитано пачкой, `attempt` — номер попытки при
    `:retry`, иначе 0;
  - метаданные: `projection` — имя, `result`, при `:retry` — `error`: модуль исключения, в том
    числе исключения колбэка (`:projection_raised`), `"<ns>/<code>"` прочих `%Core.Error{}`,
    `"exit"` или `"throw"`.
  """

  use GenServer

  alias Core.Error
  alias Core.Es.Projection
  alias Core.Es.Projection.Batch
  alias Core.Telemetry

  require Logger

  defstruct [
    :projection,
    :declaration,
    :batch_size,
    :backoff,
    :timer_ref,
    :result,
    :retry_since,
    :error,
    attempt: 0
  ]

  @typedoc "Исход цикла: отказ пачки и сбой вне её колбэков — `:retry`."
  @type result :: :processed | :idle | :locked | :outdated | :retry

  @typedoc "Интервалы опроса и текущие задержки холостого цикла и повтора."
  @type backoff :: %{
          idle_min_ms: pos_integer(),
          poll_interval_ms: pos_integer(),
          retry_min_ms: pos_integer(),
          retry_max_ms: pos_integer(),
          idle_ms: pos_integer(),
          retry_ms: pos_integer()
        }

  @type t :: %__MODULE__{
          projection: module(),
          declaration: Projection.t(),
          batch_size: pos_integer(),
          backoff: backoff(),
          timer_ref: reference() | nil,
          result: result() | nil,
          retry_since: DateTime.t() | nil,
          error: String.t() | nil,
          attempt: non_neg_integer()
        }

  @doc """
  Спецификация для Supervisor: `:id` — модуль проекции, `:shutdown` — запас на пачку, которую
  читатель дописывает под `trap_exit`.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()

  def child_spec(opts) when is_list(opts) do
    %{
      id: Keyword.fetch!(opts, :projection),
      start: {__MODULE__, :start_link, [opts]},
      shutdown: Keyword.fetch!(opts, :shutdown)
    }
  end

  @doc "Запустить читатель под именем модуля проекции."
  @spec start_link(keyword()) :: GenServer.on_start()

  def start_link(opts) when is_list(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :projection))

  @doc false
  @spec init(keyword()) :: {:ok, t()}

  @impl true
  def init(opts) do
    # Пачка идёт целиком в одном `handle_info/2`: без trap_exit остановка супервизором убила бы
    # процесс посреди транзакции, и сделанная пачкой работа откатилась бы.
    Process.flag(:trap_exit, true)
    projection = Keyword.fetch!(opts, :projection)
    declaration = projection.__es_projection__()
    :ok = Projection.Registry.register(Map.keys(declaration.streams))
    idle_min_ms = Keyword.fetch!(opts, :idle_min_ms)
    retry_min_ms = Keyword.fetch!(opts, :retry_min_ms)

    state = %__MODULE__{
      projection: projection,
      declaration: declaration,
      batch_size: Keyword.fetch!(opts, :batch_size),
      backoff: %{
        idle_min_ms: idle_min_ms,
        poll_interval_ms: Keyword.fetch!(opts, :poll_interval_ms),
        retry_min_ms: retry_min_ms,
        retry_max_ms: Keyword.fetch!(opts, :retry_max_ms),
        idle_ms: idle_min_ms,
        retry_ms: retry_min_ms
      }
    }

    {:ok, schedule(state, idle_min_ms)}
  end

  @doc false
  @spec handle_info(term(), t()) :: {:noreply, t()}

  @impl true
  def handle_info(:tick, state), do: {:noreply, cycle(state)}

  # На повторе и при чекпоинте новее версии `wake` пропускается: новые события не делают
  # проходимым событие отказа и не меняют версию строки. После `:processed` тик уже в очереди.
  def handle_info(:wake, %__MODULE__{result: result} = state)
      when is_nil(result) or result in ~w(idle locked)a,
      do: {:noreply, cycle(state)}

  def handle_info(_message, state), do: {:noreply, state}

  @doc false
  @spec terminate(term(), t()) :: :ok

  @impl true
  def terminate(reason, %__MODULE__{declaration: declaration}) do
    Logger.info(
      "проекция: читатель остановлен: projection=#{declaration.name} reason=#{inspect(reason)}"
    )

    :ok
  end

  # ---

  defp cycle(%__MODULE__{} = state) do
    _woken? = flush_wakes()
    state = cancel_timer(state)
    :ok = flush_ticks()
    start = System.monotonic_time()
    {result, events, state} = apply_outcome(run_batch(state), state)
    {delay, backoff} = next_tick(state.backoff, result, flush_wakes())
    emit_cycle(state, start, result, events)
    schedule(%{state | backoff: backoff, result: result}, delay)
  end

  # Сбой вне колбэков пачки — недоступная БД, exit, throw — такой же повтор, как её отказ: процесс
  # не падает, и супервизор не уходит в цикл рестартов на лежащей зависимости.
  defp run_batch(%__MODULE__{} = state) do
    Batch.run(state.projection, state.declaration, state.batch_size)
  rescue
    exception -> {:crash, inspect(exception.__struct__), Exception.message(exception)}
  catch
    kind, reason -> {:crash, Atom.to_string(kind), inspect(reason)}
  end

  defp apply_outcome({:processed, events}, state), do: {:processed, events, recovered(state)}

  defp apply_outcome(:outdated, %__MODULE__{result: previous} = state) do
    if previous != :outdated, do: log_outdated(state)
    {:outdated, 0, recovered(state)}
  end

  defp apply_outcome(:idle, state), do: {:idle, 0, recovered(state)}

  # Пачку держит другая нода — об отказе это ничего не говорит: серия повторов продолжается.
  defp apply_outcome(:locked, state), do: {:locked, 0, state}

  defp apply_outcome({:error, %Error{} = error, failure}, state),
    do: retried(state, error_code(error), Error.format_chain(error), failure)

  defp apply_outcome({:crash, code, reason}, state),
    do: retried(state, code, reason, %{position: nil, event_id: nil})

  # Исключение колбэка пачка отдаёт прикладной ошибкой с модулем исключения в detail: метка — модуль.
  defp error_code(%Error{ns: :es, code: :projection_raised, detail: %{exception: exception}}),
    do: inspect(exception)

  defp error_code(%Error{ns: ns, code: code}), do: "#{ns}/#{code}"

  defp recovered(%__MODULE__{} = state), do: %{state | attempt: 0, retry_since: nil, error: nil}

  defp retried(%__MODULE__{attempt: attempt} = state, code, reason, failure) do
    state = %{
      state
      | attempt: attempt + 1,
        retry_since: state.retry_since || DateTime.utc_now(),
        error: code
    }

    log_retry(state, reason, failure)
    {:retry, 0, state}
  end

  defp log_retry(%__MODULE__{declaration: declaration} = state, reason, failure) do
    Logger.warning(
      "проекция: отказ пачки, повтор: projection=#{declaration.name} " <>
        "position=#{format_position(failure.position)} event_id=#{failure.event_id || "nil"} " <>
        "attempt=#{state.attempt} причина=#{reason}"
    )
  end

  defp format_position(nil), do: "nil"
  defp format_position({xid, number}), do: "#{xid}/#{number}"

  defp log_outdated(%__MODULE__{declaration: declaration}) do
    Logger.warning(
      "проекция: чекпоинт новее версии кода, пачки пропускаются: " <>
        "projection=#{declaration.name} version=#{declaration.version}"
    )
  end

  defp emit_cycle(%__MODULE__{} = state, start, result, events) do
    :telemetry.execute(
      Telemetry.event([:es, :projection, :cycle]),
      %{
        duration: System.monotonic_time() - start,
        events: events,
        attempt: cycle_attempt(state, result)
      },
      cycle_metadata(state, result)
    )
  end

  defp cycle_attempt(%__MODULE__{attempt: attempt}, :retry), do: attempt
  defp cycle_attempt(%__MODULE__{}, _result), do: 0

  defp cycle_metadata(%__MODULE__{declaration: declaration, error: error}, :retry),
    do: %{projection: declaration.name, result: :retry, error: error}

  defp cycle_metadata(%__MODULE__{declaration: declaration}, result),
    do: %{projection: declaration.name, result: result}

  @doc false
  @spec next_tick(backoff(), result(), boolean()) :: {non_neg_integer(), backoff()}

  def next_tick(backoff, :processed, woken?) when is_boolean(woken?),
    do: {0, %{backoff | idle_ms: backoff.idle_min_ms, retry_ms: backoff.retry_min_ms}}

  def next_tick(backoff, :idle, woken?) when is_boolean(woken?),
    do: next_tick(%{backoff | retry_ms: backoff.retry_min_ms}, :locked, woken?)

  # Заблокированная пачка серию повторов не заканчивает: `retry_ms` остаётся.
  def next_tick(backoff, :locked, true), do: {0, backoff}

  def next_tick(%{idle_ms: idle_ms} = backoff, :locked, false),
    do: {idle_ms, %{backoff | idle_ms: min(idle_ms * 2, backoff.poll_interval_ms)}}

  def next_tick(%{retry_ms: retry_ms} = backoff, :retry, woken?) when is_boolean(woken?),
    do: {retry_ms, %{backoff | retry_ms: min(retry_ms * 2, backoff.retry_max_ms)}}

  def next_tick(backoff, :outdated, woken?) when is_boolean(woken?),
    do: {backoff.poll_interval_ms, %{backoff | retry_ms: backoff.retry_min_ms}}

  # ---

  defp schedule(%__MODULE__{} = state, ms),
    do: %{state | timer_ref: Process.send_after(self(), :tick, ms)}

  defp cancel_timer(%__MODULE__{timer_ref: nil} = state), do: state

  defp cancel_timer(%__MODULE__{timer_ref: ref} = state) do
    _remaining = Process.cancel_timer(ref)
    %{state | timer_ref: nil}
  end

  defp flush_wakes do
    receive do
      :wake ->
        _more? = flush_wakes()
        true
    after
      0 -> false
    end
  end

  # Таймер, сработавший до отмены, оставил `:tick` в очереди: он запустил бы цикл сразу, мимо
  # задержки повтора.
  defp flush_ticks do
    receive do
      :tick -> flush_ticks()
    after
      0 -> :ok
    end
  end
end
