defmodule Consumer.Domain.Sales.Grants.Repo do
  use Core.Es.Aggregate.Repo,
    aggregate: Consumer.Domain.Sales.Grants,
    id: Consumer.Domain.Sales.Grants.ID
end
