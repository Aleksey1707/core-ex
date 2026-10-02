defmodule Consumer.Domain.Sales.Ping.Event.Codec do
  alias Consumer.Domain.Sales.Ping.Event

  @tag_by_mod %{Event.Pinged => "ping.pinged", Event.Ponged => "ping.ponged"}

  use Core.Es.Event.Codec,
    event: Event,
    type: "ping",
    tags: @tag_by_mod
end
