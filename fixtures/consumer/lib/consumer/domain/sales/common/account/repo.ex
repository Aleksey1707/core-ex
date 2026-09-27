defmodule Consumer.Domain.Sales.Common.Account.Repo do
  use Core.Es.Aggregate.Repo,
    aggregate: Consumer.Domain.Sales.Common.Account,
    id: Consumer.Domain.Sales.Common.Account.ID
end
