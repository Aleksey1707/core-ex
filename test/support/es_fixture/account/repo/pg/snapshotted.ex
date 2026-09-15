defmodule Core.EsFixture.Account.Repo.Pg.Snapshotted do
  @moduledoc "Write-репозиторий счёта со снапшотами: снапшот пишется после двух свёрнутых событий."

  alias Core.EsFixture.Account

  use Core.Es.Aggregate.Repo.Pg,
    behaviour: Core.EsFixture.Account.Repo,
    aggregate: Account,
    id: Account.ID,
    errors: Account.Errors,
    outbox: Account.Outbox,
    snapshot: [every: 2]
end
