defmodule Consumer.Account.Cmd.Close do
  alias Consumer.UserID
  alias Core.Es

  use Core.Es.Cmd

  @enforce_keys ~w(by at)a
  defstruct @enforce_keys

  @type t :: %__MODULE__{by: UserID.t(), at: Es.Event.At.t()}
end
