defmodule Consumer.Domain.Sales.Common.Account.Cmd.Open do
  alias Consumer.Domain.Sales.Common.Account
  alias Consumer.Domain.Sales.Common.UserID
  alias Core.Es

  use Core.Es.Cmd

  @enforce_keys ~w(name by at)a
  defstruct @enforce_keys

  @type t :: %__MODULE__{name: Account.Name.t(), by: UserID.t(), at: Es.Event.At.t()}
end
