defmodule Core.Outbox.Cleaner do
  @moduledoc """
  Удаление `published` записей outbox старше TTL.

  Обязательные opts: `:repo`, `:published_ttl`, `:interval_ms`.
  Опционально: `:context_factory` (`()-> Context.t()`, вызывается один раз в `init`,
  default `Context.new/0`), `:name`, `:retry_min_ms`.

  При сбое цикла (недоступная БД) интервал не сохраняется: следующая попытка идёт
  через backoff от `retry_min_ms` с удвоением до `interval_ms` — иначе лежащая база
  опрашивалась бы с полной частотой и заливала лог.
  """

  use GenServer

  alias Core.Context
  alias Core.Error
  alias Core.Exc
  alias Core.Outbox
  alias Core.Telemetry

  require Logger
  require Error

  @default_retry_min_ms 1_000

  defstruct [:repo, :published_ttl, :interval_ms, :retry_min_ms, :retry_ms, :timer_ref, :context]

  @type t :: %__MODULE__{
          repo: module(),
          published_ttl: Outbox.PublishedTTL.t(),
          interval_ms: pos_integer(),
          retry_min_ms: pos_integer(),
          retry_ms: pos_integer(),
          timer_ref: reference() | nil,
          context: Context.t()
        }

  @doc "Запустить cleaner."
  @spec start_link(keyword()) :: GenServer.on_start()

  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc """
  Спецификация для Supervisor: `:id` = `:name`, иначе модуль.

  Без этого два cleaner'а с разными именами столкнулись бы по `:id` дефолтного
  child_spec.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()

  def child_spec(opts) when is_list(opts) do
    id =
      case Keyword.get(opts, :name) do
        nil -> __MODULE__
        name -> name
      end

    %{id: id, start: {__MODULE__, :start_link, [opts]}}
  end

  @doc "Выполнить одну очистку (для тестов)."
  @spec run_once(GenServer.server()) :: :ok | {:error, Error.t()}

  def run_once(server) do
    GenServer.call(server, :run_once, 60_000)
  end

  @doc false
  @impl true
  def init(opts) do
    interval_ms = Keyword.fetch!(opts, :interval_ms)
    retry_min_ms = min(Keyword.get(opts, :retry_min_ms, @default_retry_min_ms), interval_ms)

    state = %__MODULE__{
      repo: Keyword.fetch!(opts, :repo),
      published_ttl: Keyword.fetch!(opts, :published_ttl),
      interval_ms: interval_ms,
      retry_min_ms: retry_min_ms,
      retry_ms: retry_min_ms,
      timer_ref: nil,
      context: Keyword.get(opts, :context_factory, &Context.new/0).()
    }

    {:ok, schedule(state, interval_ms)}
  end

  @doc false
  @impl true
  def handle_call(:run_once, _from, state) do
    {:reply, clean(state), state}
  end

  @doc false
  @impl true
  def handle_info(:tick, state) do
    state = cancel_timer(state)
    {:noreply, reschedule_after(state, clean(state))}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # ---

  defp clean(%__MODULE__{context: context} = state) do
    start = System.monotonic_time()

    result =
      try do
        now = DateTime.utc_now()
        before_dt = DateTime.add(now, -Outbox.PublishedTTL.value(state.published_ttl), :second)

        case Outbox.PublishedAt.new(before_dt) do
          {:ok, before} ->
            deleted = state.repo.delete_published_before(before, context)

            if deleted > 0 do
              Logger.info(
                "Очистка outbox: удалено=#{deleted} до=#{DateTime.to_iso8601(Outbox.PublishedAt.value(before))}"
              )
            end

            {:ok, deleted}

          {:error, _} = err ->
            err
        end
      rescue
        e in [Exc] ->
          Logger.warning("Очистка outbox: #{Exception.message(e)}")
          {:error, e.error}

        e ->
          Logger.error(
            "Сбой цикла очистки outbox: #{Exception.format(:error, e, __STACKTRACE__)}"
          )

          {:error,
           Error.app(__MODULE__,
             code: :cycle_failed,
             ns: :outbox,
             message: "Сбой цикла outbox cleaner",
             detail: e
           )}
      catch
        # За delete_all стоит соединение из пула: недоступная БД приходит как exit.
        :exit, reason ->
          Logger.error("Сбой цикла очистки outbox: exit reason=#{inspect(reason)}")

          {:error,
           Error.app(__MODULE__,
             code: :cycle_exit,
             ns: :outbox,
             message: "Цикл outbox cleaner прерван exit",
             detail: reason
           )}
      end

    case result do
      {:ok, deleted} ->
        emit_cleaner_cycle(start, :ok, deleted)
        :ok

      {:error, _} = err ->
        emit_cleaner_cycle(start, :error, 0)
        err
    end
  end

  defp emit_cleaner_cycle(start, result, deleted) do
    :telemetry.execute(
      Telemetry.event([:outbox, :cleaner, :cycle]),
      %{
        duration: System.monotonic_time() - start,
        deleted: deleted
      },
      %{result: result}
    )
  end

  defp reschedule_after(state, :ok) do
    schedule(%{state | retry_ms: state.retry_min_ms}, state.interval_ms)
  end

  defp reschedule_after(state, {:error, _reason}) do
    next = min(state.retry_ms * 2, state.interval_ms)
    schedule(%{state | retry_ms: next}, state.retry_ms)
  end

  defp schedule(%__MODULE__{} = state, ms) do
    state = cancel_timer(state)
    %{state | timer_ref: Process.send_after(self(), :tick, ms)}
  end

  defp cancel_timer(%__MODULE__{timer_ref: nil} = state), do: state

  defp cancel_timer(%__MODULE__{timer_ref: ref} = state) do
    _ = Process.cancel_timer(ref)
    %{state | timer_ref: nil}
  end
end
