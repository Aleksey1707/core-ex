defmodule Consumer.Domain.Sales.Parcel.Event.Codec do
  @moduledoc "Кодек событий вне фасада: нагрузку событий он передаёт фасаду, плагина её типа нет."

  alias Consumer.Domain.Sales.Parcel.Event

  @tag_by_mod %{
    Event.Sent => "parcel.sent",
    Event.Lost => "parcel.lost",
    Event.Returned => "parcel.returned"
  }

  use Core.Es.Event.Codec,
    event: Event,
    type: "parcel",
    tags: @tag_by_mod
end
