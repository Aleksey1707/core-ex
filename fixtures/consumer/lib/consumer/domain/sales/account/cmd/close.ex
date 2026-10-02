defmodule Consumer.Domain.Sales.Account.Cmd.Close do
  alias Consumer.Domain.Sales.Values.UserID
  alias Core.Es

  use Core.Es.Cmd

  @enforce_keys ~w(by at)a
  defstruct @enforce_keys

  @type t :: %__MODULE__{by: UserID.t(), at: Es.Event.At.t()}
end
