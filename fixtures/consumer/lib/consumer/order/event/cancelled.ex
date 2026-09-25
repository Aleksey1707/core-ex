defmodule Consumer.Order.Event.Cancelled do
  alias Consumer.Order
  alias Consumer.UserID

  use Core.Es.Event,
    aggregate_id: Order.ID,
    by: UserID,
    payload: nil
end
