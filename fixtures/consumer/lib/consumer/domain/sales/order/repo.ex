defmodule Consumer.Domain.Sales.Order.Repo do
  use Core.Es.Aggregate.Repo,
    aggregate: Consumer.Domain.Sales.Order,
    id: Consumer.Domain.Sales.Order.ID
end
