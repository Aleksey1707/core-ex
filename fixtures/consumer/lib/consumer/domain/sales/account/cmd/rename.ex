defmodule Consumer.Domain.Sales.Account.Cmd.Rename do
  alias Consumer.Domain.Sales.Account
  alias Consumer.Domain.Sales.Values.UserID
  alias Core.Es

  use Core.Es.Cmd

  @enforce_keys ~w(name by at)a
  defstruct @enforce_keys

  @type t :: %__MODULE__{name: Account.Name.t(), by: UserID.t(), at: Es.Event.At.t()}
end
