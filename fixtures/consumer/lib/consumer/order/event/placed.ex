defmodule Consumer.Order.Event.Placed do
  alias Consumer.Order
  alias Consumer.UserID

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
