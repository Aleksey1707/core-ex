defmodule Consumer.Domain.Sales.Ping.Event do
  @moduledoc "События пинга."

  alias Consumer.Domain.Sales.Ping.Event.Pinged
  alias Consumer.Domain.Sales.Ping.Event.Ponged

  @type t :: Pinged.t() | Ponged.t()
end
