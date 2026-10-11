defmodule Consumer.Domain.Sales.Order.Event.Placed do
  alias Consumer.Domain.Sales.Order
  alias Consumer.Domain.Sales.Values.UserID

  defmodule Payload do
    use Core.Es.Event.Payload,
      fields: [amount: [prim: Order.Amount]]
  end

  use Core.Es.Event,
    aggregate_id: Order.ID,
    by: UserID,
    payload: Payload
end
