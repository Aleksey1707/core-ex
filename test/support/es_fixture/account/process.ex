defmodule Core.EsFixture.Account.Process do
  @moduledoc "Процесс счёта: команды через write-репозиторий `Core.EsFixture.Account.Repo`."

  use Core.Es.Aggregate.Process,
    repo: Core.EsFixture.Account.Repo
end
