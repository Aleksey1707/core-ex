defmodule Consumer.Order.Outbox do
  use Core.Es.Outbox,
    topic: "orders",
    event: Consumer.Order.Event
end
