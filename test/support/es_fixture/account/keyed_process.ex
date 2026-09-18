defmodule Core.EsFixture.Account.KeyedProcess do
  @moduledoc "Процесс счёта над репозиторием с резервом названия `Core.EsFixture.Account.KeyedRepo`."

  use Core.Es.Aggregate.Process,
    repo: Core.EsFixture.Account.KeyedRepo
end
