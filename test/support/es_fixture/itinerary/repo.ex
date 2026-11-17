defmodule Core.EsFixture.Itinerary.Repo do
  @moduledoc "Write-behaviour маршрута."

  use Core.Es.Aggregate.Repo,
    aggregate: Core.EsFixture.Itinerary
end
