defmodule Core.Es.FixtureProjectionCaseTest do
  use Core.Es.ProjectionCase,
    projection: Core.EsFixture.Projection,
    async: false
end

defmodule Core.Es.ItineraryProjectionCaseTest do
  use Core.Es.ProjectionCase,
    projection: Core.EsFixture.Itinerary.Projection,
    async: false
end
