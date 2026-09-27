defmodule Consumer.Domain.Sales.Common.Order.Event.Placed do
  alias Consumer.Domain.Sales.Common.Order
  alias Consumer.Domain.Sales.Common.UserID

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
