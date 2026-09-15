defmodule Core.EsFixture.Account.Repo do
  @moduledoc "Write-behaviour счёта."

  use Core.Es.Aggregate.Repo,
    aggregate: Core.EsFixture.Account,
    id: Core.EsFixture.Account.ID
end
