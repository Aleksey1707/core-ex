defmodule Consumer.Account.Outbox do
  use Core.Es.Outbox,
    topic: "accounts",
    event: Consumer.Account.Event
end
