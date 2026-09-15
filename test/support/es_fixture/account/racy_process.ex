defmodule Core.EsFixture.Account.RacyProcess do
  @moduledoc """
  Процесс счёта над репозиторием с гонкой записи `Core.EsFixture.Account.RacyRepo` — повтор
  команды после конфликта версии.
  """

  use Core.Es.Aggregate.Process,
    repo: Core.EsFixture.Account.RacyRepo
end
