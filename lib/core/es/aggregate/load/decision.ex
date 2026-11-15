defmodule Core.Es.Aggregate.Load.Decision do
  @moduledoc false

  alias Core.Error
  alias Core.Es.Aggregate.Load
  alias Core.Es.Aggregate.Load.Engine
  alias Core.Es.Aggregate.Repo.Pg.Config
  alias Core.Result
  alias Core.Version

  @doc "Голова потока и решение `fun` над ней; явная версия на пустом потоке решается здесь."
  @spec head(
          Config.t(),
          struct(),
          Version.expected(),
          (struct() -> Result.t(decision, reason)),
          keyword()
        ) :: Result.t(decision, reason | Error.t())
        when decision: var, reason: var

  def head(cfg, id, version, fun, opts) do
    spec = %{
      op: :get_decision,
      opts: opts,
      source: cfg.source,
      streams: [stream(struct(cfg.aggregate, id: id), version, true)]
    }

    case Load.read(cfg, spec, cfg.source.writes_snapshots?()) do
      {:ok, [state]} -> decide(cfg, state, version, fun)
      result -> result
    end
  end

  @doc "Хвост потока после `state.version` и сверка `version` с головой."
  @spec tail(Config.t(), struct(), Version.expected(), keyword()) :: Result.t(struct())

  def tail(cfg, state, version, opts) do
    spec = %{op: :refresh, opts: opts, source: cfg.source, streams: [stream(state, version, false)]}

    case Load.read(cfg, spec, cfg.source.writes_snapshots?()) do
      {:ok, [refreshed]} -> {:ok, refreshed}
      result -> result
    end
  end

  # ---

  # Пустой поток при `%Version{}` — не гонка: отказ или принятие решает `fun` на незаведённом
  # агрегате, поэтому голова спрашивает решение после сверки (ADR-0016).
  defp decide(cfg, state, %Version{} = version, fun) when is_nil(state.version) do
    case fun.(state) do
      {:ok, _decision} -> {:error, Engine.mismatch(cfg, state, Version.value(version), :expected)}
      {:error, _reason} = error -> error
    end
  end

  defp decide(_cfg, state, _version, fun), do: fun.(state)

  defp stream(state, version, born?),
    do: %{state: state, version: version, upper: nil, captures: [], born?: born?}
end
