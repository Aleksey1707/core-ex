defmodule Consumer.Domain.Sales.Order.Repo.Pg do
  alias Consumer.Domain.Sales.Order

  use Core.Es.Aggregate.Repo.Pg,
    behaviour: Consumer.Domain.Sales.Order.Repo,
    aggregate: Order,
    id: Order.ID,
    errors: Order.Errors,
    outbox: Order.Outbox
end
