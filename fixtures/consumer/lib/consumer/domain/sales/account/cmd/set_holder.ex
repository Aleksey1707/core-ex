defmodule Consumer.Domain.Sales.Account.Cmd.SetHolder do
  alias Consumer.Domain.Sales.Account
  alias Consumer.Domain.Sales.Values.UserID
  alias Core.Es

  use Core.Es.Cmd

  @enforce_keys ~w(holder by at)a
  defstruct @enforce_keys

  @type t :: %__MODULE__{holder: Account.Holder.t(), by: UserID.t(), at: Es.Event.At.t()}
end
