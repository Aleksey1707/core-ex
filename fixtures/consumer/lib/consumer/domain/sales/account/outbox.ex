defmodule Consumer.Domain.Sales.Account.Outbox do
  use Core.Es.Outbox,
    topic: "accounts",
    family: Consumer.Domain.Sales.Account.Event
end
