defmodule Consumer.Domain.Sales.Common.Ping.Event.Pinged do
  alias Consumer.Domain.Sales.Common.Ping
  alias Consumer.Domain.Sales.Common.UserID

  use Core.Es.Event,
    aggregate_id: Ping.ID,
    by: UserID,
    payload: nil
end
