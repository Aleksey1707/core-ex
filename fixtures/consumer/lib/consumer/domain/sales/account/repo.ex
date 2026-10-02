defmodule Consumer.Domain.Sales.Account.Repo do
  use Core.Es.Aggregate.Repo,
    aggregate: Consumer.Domain.Sales.Account,
    id: Consumer.Domain.Sales.Account.ID
end
