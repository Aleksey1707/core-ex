defmodule Core.EsFixture.Account.KeyedRepo.Pg do
  @moduledoc """
  Write-репозиторий счёта с резервами названия `Core.EsFixture.Account.NameKey` и владельца —
  ключа из ПДн `Core.EsFixture.Account.HolderKey`.
  """

  alias Core.EsFixture.Account

  use Core.Es.Aggregate.Repo.Pg,
    behaviour: Core.EsFixture.Account.KeyedRepo,
    errors: Account.Errors,
    outbox: Account.Outbox,
    key_reservations: [Account.NameKey, Account.HolderKey]
end
