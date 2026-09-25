defmodule Consumer.Order.Event do
  @moduledoc "События заказа."

  alias Consumer.Order.Event.Cancelled
  alias Consumer.Order.Event.Placed

  @type t :: Placed.t() | Cancelled.t()
end
