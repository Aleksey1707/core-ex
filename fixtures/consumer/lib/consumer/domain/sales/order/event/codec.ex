defmodule Consumer.Domain.Sales.Order.Event.Codec do
  alias Consumer.Domain.Sales.Order.Event

  @tag_by_mod %{Event.Placed => "order.placed", Event.Cancelled => "order.cancelled"}

  use Core.Es.Event.Codec,
    family: Event,
    type: "order",
    tags: @tag_by_mod
end
