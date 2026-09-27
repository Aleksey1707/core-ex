defmodule Consumer.Domain.Sales.Common.Ping.Event.Ponged do
  alias Consumer.Domain.Sales.Common.Ping
  alias Consumer.Domain.Sales.Common.UserID

  use Core.Es.Event,
    aggregate_id: Ping.ID,
    by: UserID,
    payload: nil
end
