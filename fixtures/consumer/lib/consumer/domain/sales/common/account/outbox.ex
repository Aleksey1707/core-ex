defmodule Consumer.Domain.Sales.Common.Account.Outbox do
  use Core.Es.Outbox,
    topic: "accounts",
    event: Consumer.Domain.Sales.Common.Account.Event
end
