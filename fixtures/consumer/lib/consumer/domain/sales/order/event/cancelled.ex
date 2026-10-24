defmodule Consumer.Domain.Sales.Order.Event.Cancelled do
  alias Consumer.Domain.Sales.Order

  use Core.Es.Event,
    family: Order.Event,
    payload: nil
end
