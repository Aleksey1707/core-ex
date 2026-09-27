defmodule Consumer.Domain.Sales.Common.Ping.Repo do
  use Core.Es.Aggregate.Repo,
    aggregate: Consumer.Domain.Sales.Common.Ping,
    id: Consumer.Domain.Sales.Common.Ping.ID
end
