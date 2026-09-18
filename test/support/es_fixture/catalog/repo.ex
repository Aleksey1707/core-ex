defmodule Core.EsFixture.Catalog.Repo do
  @moduledoc "Write-behaviour каталога."

  use Core.Es.Aggregate.Repo,
    aggregate: Core.EsFixture.Catalog,
    id: Core.EventFixture.AggID
end
