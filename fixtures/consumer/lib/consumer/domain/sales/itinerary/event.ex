defmodule Consumer.Domain.Sales.Itinerary.Event do
  @moduledoc "События маршрута."

  alias Consumer.Domain.Sales.Itinerary
  alias Consumer.Domain.Sales.Itinerary.Event.Planned
  alias Consumer.Domain.Sales.Values.UserID

  use Core.Es.Event.Family,
    aggregate: Itinerary,
    aggregate_id: Itinerary.ID,
    by: UserID,
    codec: Itinerary.Event.Codec

  @type t :: Planned.t()
end
