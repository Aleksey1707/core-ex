defmodule Core.EsFixture.Account.SecondKeyedProcess do
  @moduledoc """
  Процесс счёта над репозиторием `Core.EsFixture.Account.SecondKeyedRepo`: события и резерв
  названия — на `dao` репозитория.
  """

  use Core.Es.Aggregate.Process,
    repo: Core.EsFixture.Account.SecondKeyedRepo
end
