defmodule Core.EsFixture.Account.Cmd.SetHolder do
  @moduledoc "Указать владельца счёта."

  alias Core.Es
  alias Core.EsFixture.Account.Holder
  alias Core.EsFixture.UserID

  use Core.Es.Cmd

  @enforce_keys ~w(holder by at)a
  defstruct @enforce_keys

  @type t :: %__MODULE__{holder: Holder.t(), by: UserID.t(), at: Es.Event.At.t()}
end
