defmodule Consumer.Ping.Event.Codec do
  alias Consumer.Ping.Event

  @tag_by_mod %{Event.Pinged => "ping.pinged", Event.Ponged => "ping.ponged"}

  use Core.Es.Event.Codec,
    event: Event,
    type: "ping",
    tags: @tag_by_mod
end
