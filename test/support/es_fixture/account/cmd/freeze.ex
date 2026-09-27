defmodule Core.EsFixture.Account.Cmd.Freeze do
  @moduledoc "Заморозить счёт."

  alias Core.Es
  alias Core.EsFixture.UserID

  use Core.Es.Cmd

  @enforce_keys ~w(by at)a
  defstruct @enforce_keys

  @type t :: %__MODULE__{by: UserID.t(), at: Es.Event.At.t()}
end
