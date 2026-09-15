defmodule Core.EsFixture.Account.RacyRepo do
  @moduledoc "Write-behaviour счёта с гонкой записи; реализация — `Core.EsFixture.Account.RacyRepo.Pg`."

  use Core.Es.Aggregate.Repo,
    aggregate: Core.EsFixture.Account,
    id: Core.EsFixture.Account.ID
end
