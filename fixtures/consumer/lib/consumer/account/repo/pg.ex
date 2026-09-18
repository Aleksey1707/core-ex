defmodule Consumer.Account.Repo.Pg do
  alias Consumer.Account

  use Core.Es.Aggregate.Repo.Pg,
    behaviour: Consumer.Account.Repo,
    aggregate: Account,
    id: Account.ID,
    errors: Account.Errors,
    outbox: Account.Outbox,
    key_reservations: [Account.NameKey]
end
