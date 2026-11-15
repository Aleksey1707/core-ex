defmodule Core.EsFixture.Account.SecondKeyedRepo do
  @moduledoc """
  Write-behaviour счёта с резервом названия и `dao` второго тестового репозитория
  `Core.TestRepoSecond`.

  Реализация — `Core.EsFixture.Account.SecondKeyedRepo.Pg`; резерв должен ставиться в транзакции
  команды, то есть на её `dao`, а не на `Core.Config.dao/0`.
  """

  use Core.Es.Aggregate.Repo,
    aggregate: Core.EsFixture.Account
end
