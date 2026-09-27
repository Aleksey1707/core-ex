defmodule Consumer.Domain.Sales.Common.Ping.Event do
  @moduledoc "События пинга."

  alias Consumer.Domain.Sales.Common.Ping.Event.Pinged
  alias Consumer.Domain.Sales.Common.Ping.Event.Ponged

  @type t :: Pinged.t() | Ponged.t()
end
