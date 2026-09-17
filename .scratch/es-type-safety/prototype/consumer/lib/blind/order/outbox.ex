defmodule Blind.Order.Outbox do
  use Core.Es.Outbox,
    topic: "orders",
    event: Blind.Order.Event
end
