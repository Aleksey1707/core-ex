defmodule Core.EsFixture.Account.KeyedRepo do
  @moduledoc """
  Write-behaviour счёта с резервами названия и владельца; реализация —
  `Core.EsFixture.Account.KeyedRepo.Pg`.
  """

  use Core.Es.Aggregate.Repo,
    aggregate: Core.EsFixture.Account
end
