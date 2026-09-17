defmodule Blind.Account.Outbox do
  use Core.Es.Outbox,
    topic: "accounts",
    event: Blind.Account.Event
end
