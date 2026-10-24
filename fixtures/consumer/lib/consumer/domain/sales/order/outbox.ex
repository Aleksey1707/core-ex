defmodule Consumer.Domain.Sales.Order.Outbox do
  use Core.Es.Outbox,
    topic: "orders",
    family: Consumer.Domain.Sales.Order.Event
end
