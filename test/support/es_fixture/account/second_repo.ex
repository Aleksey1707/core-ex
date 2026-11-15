defmodule Core.EsFixture.Account.SecondRepo do
  @moduledoc """
  Write-behaviour счёта с `dao` второго тестового репозитория `Core.TestRepoSecond`.

  Реализация — `Core.EsFixture.Account.SecondRepo.Pg`; нужна тестам владельца `dao` команды.
  """

  use Core.Es.Aggregate.Repo,
    aggregate: Core.EsFixture.Account
end
