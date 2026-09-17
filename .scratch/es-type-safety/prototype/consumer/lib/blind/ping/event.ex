defmodule Blind.Ping.Event do
  alias Blind.Ping
  alias Blind.UserID

  defmodule Pinged do
    use Core.Es.Event,
      aggregate_id: Ping.ID,
      by: UserID,
      payload: nil
  end

  defmodule Ponged do
    use Core.Es.Event,
      aggregate_id: Ping.ID,
      by: UserID,
      payload: nil
  end

  @type t :: Pinged.t() | Ponged.t()
end

defmodule Blind.Ping.Event.Codec do
  alias Blind.Ping.Event

  @tag_by_mod %{Event.Pinged => "ping.pinged", Event.Ponged => "ping.ponged"}

  use Core.Es.Event.Codec,
    event: Event,
    type: "ping",
    tags: @tag_by_mod
end
