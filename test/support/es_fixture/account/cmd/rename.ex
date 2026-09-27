defmodule Core.EsFixture.Account.Cmd.Rename do
  @moduledoc "Переименовать счёт."

  alias Core.Es
  alias Core.EsFixture.Account.Name
  alias Core.EsFixture.UserID

  use Core.Es.Cmd

  @enforce_keys ~w(name by at)a
  defstruct @enforce_keys

  @type t :: %__MODULE__{name: Name.t(), by: UserID.t(), at: Es.Event.At.t()}
end
