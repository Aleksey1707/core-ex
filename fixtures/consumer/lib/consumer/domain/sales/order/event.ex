defmodule Consumer.Domain.Sales.Order.Event do
  @moduledoc "События заказа."

  alias Consumer.Domain.Sales.Order
  alias Consumer.Domain.Sales.Order.Event.Cancelled
  alias Consumer.Domain.Sales.Order.Event.Placed
  alias Consumer.Domain.Sales.Values.UserID

  use Core.Es.Event.Family,
    aggregate: Order,
    aggregate_id: Order.ID,
    by: UserID,
    codec: Order.Event.Codec

  @type t :: Placed.t() | Cancelled.t()
end
