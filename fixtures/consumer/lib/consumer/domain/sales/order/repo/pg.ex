defmodule Consumer.Domain.Sales.Order.Repo.Pg do
  alias Consumer.Domain.Sales.Order

  use Core.Es.Aggregate.Repo.Pg,
    behaviour: Consumer.Domain.Sales.Order.Repo,
    errors: Order.Errors,
    outbox: Order.Outbox
end
