defmodule Consumer.Domain.Sales.Account.Repo.Pg do
  alias Consumer.Domain.Sales.Account

  use Core.Es.Aggregate.Repo.Pg,
    behaviour: Consumer.Domain.Sales.Account.Repo,
    errors: Account.Errors,
    outbox: Account.Outbox,
    key_reservations: [Account.NameKey, Account.HolderKey]
end
