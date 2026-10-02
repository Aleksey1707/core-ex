defmodule Consumer.Domain.Sales.Order.Event.Placed do
  alias Consumer.Domain.Sales.Order
  alias Consumer.Domain.Sales.Values.UserID

  defmodule Payload do
    @enforce_keys ~w(amount)a
    defstruct @enforce_keys

    def new(%Order.Amount{} = amount), do: %__MODULE__{amount: amount}
  end

  use Core.Es.Event,
    aggregate_id: Order.ID,
    by: UserID,
    payload: Payload
end
