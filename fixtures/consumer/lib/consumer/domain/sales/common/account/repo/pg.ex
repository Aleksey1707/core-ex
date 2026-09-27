defmodule Consumer.Domain.Sales.Common.Account.Repo.Pg do
  alias Consumer.Domain.Sales.Common.Account

  use Core.Es.Aggregate.Repo.Pg,
    behaviour: Consumer.Domain.Sales.Common.Account.Repo,
    aggregate: Account,
    id: Account.ID,
    errors: Account.Errors,
    outbox: Account.Outbox,
    key_reservations: [Account.NameKey]
end
