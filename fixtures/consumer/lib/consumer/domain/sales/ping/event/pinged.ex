defmodule Consumer.Domain.Sales.Ping.Event.Pinged do
  alias Consumer.Domain.Sales.Ping
  alias Consumer.Domain.Sales.Values.UserID

  use Core.Es.Event,
    aggregate_id: Ping.ID,
    by: UserID,
    payload: nil
end
