defmodule Consumer.Domain.Sales.Order.Event.Placed do
  alias Consumer.Domain.Sales.Order

  defmodule Payload do
    use Core.Es.Event.Payload,
      fields: [amount: [prim: Order.Amount]]
  end

  use Core.Es.Event,
    family: Order.Event,
    payload: Payload
end
