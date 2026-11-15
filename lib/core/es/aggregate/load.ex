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

  @doc false
  @spec run(Config.t(), Request.t()) :: Result.t([struct()] | struct())

  def run(cfg, %Request{} = request), do: read(cfg, request, writes_snapshots?(request))

  @doc false
  @spec read(Config.t(), Engine.spec(), boolean()) :: Result.t([struct()] | struct())

  def read(cfg, %{op: op, streams: streams} = spec, snapshots?) do
    start = System.monotonic_time()
    plan = Plan.new(cfg, snapshots?, streams)

    with {:ok, %{restored: restored, result: result}} <- Engine.read(cfg, plan, spec) do
      :telemetry.execute(
        Telemetry.event([:es, :aggregate, :load]),
        measurements(restored, System.monotonic_time() - start),
        %{type: cfg.type, op: op, result: result_tag(result)}
      )

      write_snapshots(cfg, plan, restored)
      result
    end
  end

  # ---

  # Политика записи снапшота — свойство операции и возможность источника строк.
  defp writes_snapshots?(%Request{op: op, source: source}),
    do: op in [:get, :get_many] and source.writes_snapshots?()

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
