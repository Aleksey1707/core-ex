defmodule Consumer.Order.Event do
  alias Consumer.Order
  alias Consumer.UserID

  defmodule Placed do
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

  defmodule Cancelled do
    use Core.Es.Event,
      aggregate_id: Order.ID,
      by: UserID,
      payload: nil
  end

  @type t :: Placed.t() | Cancelled.t()
end
