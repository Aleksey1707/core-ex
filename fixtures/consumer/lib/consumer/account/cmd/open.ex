defmodule Consumer.Account.Cmd.Open do
  alias Consumer.Account
  alias Consumer.UserID
  alias Core.Es

  use Core.Es.Cmd

  @enforce_keys ~w(name by at)a
  defstruct @enforce_keys

  @type t :: %__MODULE__{name: Account.Name.t(), by: UserID.t(), at: Es.Event.At.t()}
end
