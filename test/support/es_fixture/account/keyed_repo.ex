defmodule Core.EsFixture.Account.KeyedRepo do
  @moduledoc "Write-behaviour счёта с резервом названия; реализация — `Core.EsFixture.Account.KeyedRepo.Pg`."

  use Core.Es.Aggregate.Repo,
    aggregate: Core.EsFixture.Account,
    id: Core.EsFixture.Account.ID
end
