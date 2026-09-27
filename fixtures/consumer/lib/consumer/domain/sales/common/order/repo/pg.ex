defmodule Consumer.Domain.Sales.Common.Order.Repo.Pg do
  alias Consumer.Domain.Sales.Common.Order

  use Core.Es.Aggregate.Repo.Pg,
    behaviour: Consumer.Domain.Sales.Common.Order.Repo,
    aggregate: Order,
    id: Order.ID,
    errors: Order.Errors,
    outbox: Order.Outbox
end
