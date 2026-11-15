defmodule Core.Es.Aggregate.Load.Source do
  @moduledoc false

  alias Core.Es.Aggregate.Load.Plan
  alias Core.Es.Aggregate.Repo.Pg.Config
  alias Core.Es.Aggregate.Repo.Pg.Snapshot
  alias Core.Es.Store.Schema

  @typedoc false
  @type entry :: {Plan.stream(), Snapshot.stored() | nil, [Schema.t()]}

  @callback fetch(Config.t(), Plan.t(), keyword()) :: [entry()]
end
