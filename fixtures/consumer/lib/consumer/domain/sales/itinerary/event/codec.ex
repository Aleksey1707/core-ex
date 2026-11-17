defmodule Consumer.Domain.Sales.Itinerary.Event.Codec do
  @moduledoc "Кодек событий маршрута."

  alias Consumer.Domain.Sales.Itinerary.Event

  @tag_by_mod %{Event.Planned => "itinerary.planned"}

  use Core.Es.Event.Codec,
    family: Event,
    type: "itinerary",
    tags: @tag_by_mod
end
