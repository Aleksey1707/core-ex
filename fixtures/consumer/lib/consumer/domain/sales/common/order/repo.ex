defmodule Consumer.Domain.Sales.Common.Order.Repo do
  use Core.Es.Aggregate.Repo,
    aggregate: Consumer.Domain.Sales.Common.Order,
    id: Consumer.Domain.Sales.Common.Order.ID
end
