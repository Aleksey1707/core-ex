defmodule Consumer.Domain.Sales.Common.Order.Event do
  @moduledoc "События заказа."

  alias Consumer.Domain.Sales.Common.Order.Event.Cancelled
  alias Consumer.Domain.Sales.Common.Order.Event.Placed

  @type t :: Placed.t() | Cancelled.t()
end
