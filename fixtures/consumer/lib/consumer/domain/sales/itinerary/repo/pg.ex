defmodule Consumer.Domain.Sales.Itinerary.Repo.Pg do
  alias Consumer.Domain.Sales.Itinerary

  use Core.Es.Aggregate.Repo.Pg,
    behaviour: Itinerary.Repo,
    errors: Itinerary.Errors,
    outbox: Itinerary.Outbox
end
