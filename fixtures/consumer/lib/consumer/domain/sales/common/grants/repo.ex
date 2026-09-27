defmodule Consumer.Domain.Sales.Common.Grants.Repo do
  use Core.Es.Aggregate.Repo,
    aggregate: Consumer.Domain.Sales.Common.Grants,
    id: Consumer.Domain.Sales.Common.Grants.ID
end
