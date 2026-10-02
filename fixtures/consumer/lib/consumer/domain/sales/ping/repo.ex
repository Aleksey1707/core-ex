defmodule Consumer.Domain.Sales.Ping.Repo do
  use Core.Es.Aggregate.Repo,
    aggregate: Consumer.Domain.Sales.Ping,
    id: Consumer.Domain.Sales.Ping.ID
end
