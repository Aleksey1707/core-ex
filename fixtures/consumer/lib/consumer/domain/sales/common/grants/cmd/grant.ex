defmodule Consumer.Domain.Sales.Common.Grants.Cmd.Grant do
  alias Consumer.Domain.Sales.Common.Grants
  alias Consumer.Domain.Sales.Common.UserID
  alias Core.Es

  use Core.Es.Cmd

  @enforce_keys ~w(role by at)a
  defstruct @enforce_keys

  @type t :: %__MODULE__{role: Grants.RoleID.t(), by: UserID.t(), at: Es.Event.At.t()}
end
