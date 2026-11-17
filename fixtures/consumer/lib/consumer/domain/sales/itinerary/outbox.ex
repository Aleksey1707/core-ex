defmodule Consumer.Domain.Sales.Itinerary.Outbox do
  use Core.Es.Outbox,
    topic: "itineraries",
    family: Consumer.Domain.Sales.Itinerary.Event
end
