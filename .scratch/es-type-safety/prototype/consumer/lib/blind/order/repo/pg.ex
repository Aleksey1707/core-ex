defmodule Blind.Order.Repo.Pg do
  alias Blind.Order

  use Core.Es.Aggregate.Repo.Pg,
    behaviour: Blind.Order.Repo,
    aggregate: Order,
    id: Order.ID,
    errors: Order.Errors,
    outbox: Order.Outbox
end
