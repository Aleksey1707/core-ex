defmodule Consumer.Domain.Sales.Ping.Event do
  @moduledoc "События пинга."

  alias Consumer.Domain.Sales.Ping
  alias Consumer.Domain.Sales.Ping.Event.Pinged
  alias Consumer.Domain.Sales.Ping.Event.Ponged
  alias Consumer.Domain.Sales.Values.UserID

  use Core.Es.Event.Family,
    aggregate: Ping,
    aggregate_id: Ping.ID,
    by: UserID,
    codec: Ping.Event.Codec

  @type t :: Pinged.t() | Ponged.t()
end
