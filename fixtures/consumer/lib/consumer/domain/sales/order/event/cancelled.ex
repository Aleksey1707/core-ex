defmodule Consumer.Domain.Sales.Order.Event.Cancelled do
  alias Consumer.Domain.Sales.Order
  alias Consumer.Domain.Sales.Values.UserID

  use Core.Es.Event,
    aggregate_id: Order.ID,
    by: UserID,
    payload: nil
end
