defmodule Core.EsFixture.Account.Repo.Pg do
  @moduledoc "Write-репозиторий счёта."

  alias Core.EsFixture.Account

  use Core.Es.Aggregate.Repo.Pg,
    behaviour: Core.EsFixture.Account.Repo,
    errors: Account.Errors,
    outbox: Account.Outbox
end
