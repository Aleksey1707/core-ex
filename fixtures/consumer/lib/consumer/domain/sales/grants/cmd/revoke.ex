defmodule Consumer.Domain.Sales.Grants.Cmd.Revoke do
  alias Consumer.Domain.Sales.Grants
  alias Consumer.Domain.Sales.Values.UserID
  alias Core.Es

  use Core.Es.Cmd

  @enforce_keys ~w(role by at)a
  defstruct @enforce_keys

  @type t :: %__MODULE__{role: Grants.RoleID.t(), by: UserID.t(), at: Es.Event.At.t()}
end
