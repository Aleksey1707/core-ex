defmodule Consumer.Order.Repo.Pg do
  alias Consumer.Order

  use Core.Es.Aggregate.Repo.Pg,
    behaviour: Consumer.Order.Repo,
    aggregate: Order,
    id: Order.ID,
    errors: Order.Errors,
    outbox: Order.Outbox
end
