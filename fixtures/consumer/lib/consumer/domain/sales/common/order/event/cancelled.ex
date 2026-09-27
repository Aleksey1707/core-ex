defmodule Consumer.Domain.Sales.Common.Order.Event.Cancelled do
  alias Consumer.Domain.Sales.Common.Order
  alias Consumer.Domain.Sales.Common.UserID

  use Core.Es.Event,
    aggregate_id: Order.ID,
    by: UserID,
    payload: nil
end
