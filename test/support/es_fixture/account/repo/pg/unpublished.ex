defmodule Core.EsFixture.Account.Repo.Pg.Unpublished do
  @moduledoc "Write-репозиторий счёта без публикации наружу: `outbox: :none`."

  alias Core.EsFixture.Account

  use Core.Es.Aggregate.Repo.Pg,
    behaviour: Core.EsFixture.Account.Repo,
    aggregate: Account,
    id: Account.ID,
    errors: Account.Errors,
    outbox: :none
end
