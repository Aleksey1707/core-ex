defmodule Consumer.Domain.Sales.Order.Event do
  @moduledoc "События заказа."

  alias Consumer.Domain.Sales.Order.Event.Cancelled
  alias Consumer.Domain.Sales.Order.Event.Placed

  @type t :: Placed.t() | Cancelled.t()
end
