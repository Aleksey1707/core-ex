defmodule Core.Es.Aggregate.Load do
  @moduledoc false

  alias Core.Error
  alias Core.Es.Aggregate.Load.Engine
  alias Core.Es.Aggregate.Load.Plan
  alias Core.Es.Aggregate.Load.Request
  alias Core.Es.Aggregate.Repo.Pg.Config
  alias Core.Es.Aggregate.Repo.Pg.Snapshot
  alias Core.Result
  alias Core.Telemetry
  alias Core.Version

  @typedoc false
  @type request(decision, reason) :: Request.t(decision, reason)

  @typedoc false
  @type request :: request(term(), term())

  @doc false
  @spec run(Config.t(), request(decision, reason)) :: Result.t([struct()] | struct() | decision, reason | Error.t())
        when decision: var, reason: var

  def run(cfg, %Request{op: op} = request) do
    start = System.monotonic_time()
    plan = Plan.new(cfg, writes_snapshots?(request), request.streams)

    with {:ok, %{restored: restored, result: result}} <- Engine.read(cfg, plan, request) do
      :telemetry.execute(
        Telemetry.event([:es, :aggregate, :load]),
        measurements(restored, System.monotonic_time() - start),
        %{type: cfg.type, op: op, result: result_tag(result)}
      )

      write_snapshots(cfg, plan, restored)
      decide(cfg, request, result)
    end
  end

  # ---

  # Политика записи снапшота — свойство операции и возможность источника строк.
  defp writes_snapshots?(%Request{op: op, source: source}),
    do: op in [:get, :get_decision, :get_many, :refresh] and source.writes_snapshots?()

  # Пустой поток при `%Version{}` — не гонка: отказ или принятие решает `fun` на незаведённом
  # агрегате, поэтому одиночное чтение головы спрашивает решение после сверки (ADR-0016).
  defp decide(cfg, %{decide: fun, streams: [%{version: %Version{} = version}]}, {:ok, [state]})
       when is_function(fun, 1) and is_nil(state.version) do
    case fun.(state) do
      {:ok, _decision} -> {:error, Engine.mismatch(cfg, state, Version.value(version), :expected)}
      {:error, _reason} = error -> error
    end
  end

  defp decide(_cfg, %{decide: fun}, {:ok, [state]}) when is_function(fun, 1), do: fun.(state)

  defp decide(_cfg, _request, result), do: result

  defp measurements(restored, duration) do
    counts = Enum.frequencies_by(restored, & &1.snapshot)

    %{
      duration: duration,
      streams: length(restored),
      events: Enum.sum_by(restored, & &1.events),
      snapshot_hit: Map.get(counts, :hit, 0),
      snapshot_miss: Map.get(counts, :miss, 0),
      snapshot_rejected: Map.get(counts, :rejected, 0)
    }
  end

  defp write_snapshots(%Config{snapshot: nil}, _plan, _restored), do: :ok

  defp write_snapshots(_cfg, %{write_snapshots?: false}, _restored), do: :ok

  defp write_snapshots(cfg, %{every: every} = plan, restored) do
    states = for %{state: state, events: events, destroyed?: false} <- restored, events >= every, do: state
    Snapshot.write(cfg, plan, states)
  end

  defp result_tag({:ok, _}), do: :ok
  defp result_tag({:error, %Error{code: :version_mismatch}}), do: :version_mismatch
end
