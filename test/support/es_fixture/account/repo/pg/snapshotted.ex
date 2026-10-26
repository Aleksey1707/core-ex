defmodule Core.EsFixture.Account.Repo.Pg.Snapshotted do
  @moduledoc """
  Write-репозиторий счёта со снапшотами: снапшот пишется после двух свёрнутых событий.

  Второй репозиторий одного агрегата — только тестовая фикстура контракта: у агрегата репозиторий
  один (`docs/rules/13-repos.md`, «Write event-sourced агрегата (`use Core.Es.Aggregate.Repo.Pg`)»).
  """

  alias Core.EsFixture.Account

  use Core.Es.Aggregate.Repo.Pg,
    behaviour: Core.EsFixture.Account.Repo,
    errors: Account.Errors,
    outbox: Account.Outbox,
    snapshot: [every: 2]
end
