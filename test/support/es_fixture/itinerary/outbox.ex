defmodule Core.EsFixture.Itinerary.Outbox do
  @moduledoc "Маппинг событий маршрута в записи outbox."

  use Core.Es.Outbox,
    topic: "itineraries",
    family: Core.EsFixture.Itinerary.Event
end
