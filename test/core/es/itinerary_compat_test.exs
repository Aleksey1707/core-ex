defmodule Core.Es.ItineraryCompatTest do
  use Core.Es.EventCompatCase,
    aggregate: Core.EsFixture.Itinerary,
    async: true
end
