defmodule Core.EsFixture.Itinerary.Event.Codec do
  @moduledoc "Кодек событий маршрута (плагин фасадов `Core.CodecFixture.*`)."

  alias Core.Es
  alias Core.EsFixture.Itinerary.Event

  @tag_by_mod %{
    Event.Planned => "itinerary.planned",
    Event.RecipientChanged => "itinerary.recipient_changed",
    Event.StepRecorded => "itinerary.step_recorded"
  }

  use Es.Event.Codec,
    family: Event,
    type: "itinerary",
    tags: @tag_by_mod
end
