defmodule Consumer.Ping.Event do
  @moduledoc "События пинга."

  alias Consumer.Ping.Event.Pinged
  alias Consumer.Ping.Event.Ponged

  @type t :: Pinged.t() | Ponged.t()
end
