defmodule Consumer.Grants.Cmd.Revoke do
  alias Consumer.Grants
  alias Consumer.UserID
  alias Core.Es

  use Core.Es.Cmd

  @enforce_keys ~w(role by at)a
  defstruct @enforce_keys

  @type t :: %__MODULE__{role: Grants.RoleID.t(), by: UserID.t(), at: Es.Event.At.t()}
end
