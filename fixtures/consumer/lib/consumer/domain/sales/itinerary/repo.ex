defmodule Consumer.Domain.Sales.Itinerary.Repo do
  use Core.Es.Aggregate.Repo,
    aggregate: Consumer.Domain.Sales.Itinerary
end
