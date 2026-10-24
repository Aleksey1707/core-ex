defmodule Consumer.Domain.Sales.Order.Repo do
  use Core.Es.Aggregate.Repo,
    aggregate: Consumer.Domain.Sales.Order
end
