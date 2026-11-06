defmodule Core.EsFixture.Account.Repo.Snapshotted do
  @moduledoc """
  Write-behaviour счёта со снапшотами — для контракта чтения состояния на версии.

  Второй репозиторий одного агрегата — только тестовая фикстура: у агрегата репозиторий один
  (`docs/rules/13-repos.md`, «Write event-sourced агрегата (`use Core.Es.Aggregate.Repo.Pg`)»).
  """

  use Core.Es.Aggregate.Repo,
    aggregate: Core.EsFixture.Account
end
