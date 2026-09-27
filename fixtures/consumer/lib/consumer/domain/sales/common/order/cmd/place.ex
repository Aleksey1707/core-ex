defmodule Consumer.Domain.Sales.Common.Order.Cmd.Place do
  alias Consumer.Domain.Sales.Common.Order
  alias Consumer.Domain.Sales.Common.UserID
  alias Core.Es

  use Core.Es.Cmd

  @enforce_keys ~w(amount by at)a
  defstruct @enforce_keys

  @type t :: %__MODULE__{amount: Order.Amount.t(), by: UserID.t(), at: Es.Event.At.t()}
end
