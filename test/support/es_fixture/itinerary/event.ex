defmodule Core.EsFixture.Itinerary.Event do
  @moduledoc "Семейство событий маршрута."

  alias Core.EsFixture.Itinerary.Event.Planned
  alias Core.EsFixture.Itinerary.Event.RecipientChanged
  alias Core.EsFixture.Itinerary.Event.StepRecorded
  alias Core.EsFixture.UserID

  use Core.Es.Event.Family,
    aggregate: Core.EsFixture.Itinerary,
    aggregate_id: Core.EsFixture.Itinerary.ID,
    by: UserID,
    codec: Core.EsFixture.Itinerary.Event.Codec

  @type t :: Planned.t() | RecipientChanged.t() | StepRecorded.t()
end
