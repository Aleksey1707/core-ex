defmodule Core.EsFixture.Account.KeyedRepo.Pg do
  @moduledoc "Write-репозиторий счёта с резервом названия `Core.EsFixture.Account.NameKey`."

  alias Core.EsFixture.Account

  use Core.Es.Aggregate.Repo.Pg,
    behaviour: Core.EsFixture.Account.KeyedRepo,
    aggregate: Account,
    id: Account.ID,
    errors: Account.Errors,
    outbox: Account.Outbox,
    key_reservations: [Account.NameKey]
end
