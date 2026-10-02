defmodule Consumer.Domain.Sales.Order.Outbox do
  use Core.Es.Outbox,
    topic: "orders",
    event: Consumer.Domain.Sales.Order.Event
end
