defmodule Consumer.Domain.Sales.Common.Order.Outbox do
  use Core.Es.Outbox,
    topic: "orders",
    event: Consumer.Domain.Sales.Common.Order.Event
end
