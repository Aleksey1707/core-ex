defmodule Core.EsFixture.Account.SecondProcess do
  @moduledoc "Процесс счёта над репозиторием `Core.EsFixture.Account.SecondRepo`."

  use Core.Es.Aggregate.Process,
    repo: Core.EsFixture.Account.SecondRepo
end
