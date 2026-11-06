defmodule Core.EsFixture.Account.AtVersion.Snapshotted.ReadRepo do
  @moduledoc """
  Чтение счёта на версии над write-репозиторием со снапшотами.

  Второй репозиторий одного агрегата — только тестовая фикстура: у агрегата репозиторий один
  (`docs/rules/13-repos.md`, «Write event-sourced агрегата (`use Core.Es.Aggregate.Repo.Pg`)»).
  """

  use Core.Es.Aggregate.ReadRepo,
    repo: Core.EsFixture.Account.Repo.Snapshotted,
    view: Core.EsFixture.Account.AtVersion.View
end
