defmodule Core.EsFixture.Account.SecondKeyedRepo.Pg do
  @moduledoc """
  Write-репозиторий счёта на `dao` второго тестового репозитория с резервом названия
  `Core.EsFixture.Account.NameKey`.

  `outbox: :none` — проверяются события и резерв в одной транзакции репозитория.
  """

  alias Core.EsFixture.Account

  use Core.Es.Aggregate.Repo.Pg,
    behaviour: Core.EsFixture.Account.SecondKeyedRepo,
    errors: Account.Errors,
    outbox: :none,
    repo: Core.TestRepoSecond,
    key_reservations: [Account.NameKey]
end
