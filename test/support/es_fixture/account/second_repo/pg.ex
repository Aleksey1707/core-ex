defmodule Core.EsFixture.Account.SecondRepo.Pg do
  @moduledoc """
  Write-репозиторий счёта на `dao` второго тестового репозитория: транзакция, чтение и запись
  событий идут на `Core.TestRepoSecond`, а не на `Core.Config.dao/0`.

  `outbox: :none` — проверяется транзакция самого потока событий, без записей outbox.
  """

  alias Core.EsFixture.Account

  use Core.Es.Aggregate.Repo.Pg,
    behaviour: Core.EsFixture.Account.SecondRepo,
    errors: Account.Errors,
    outbox: :none,
    repo: Core.TestRepoSecond
end
