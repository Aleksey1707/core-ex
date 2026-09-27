defmodule Core.EsFixture.Account.Event.Opened do
  @moduledoc "Счёт открыт."

  alias Core.EsFixture.Account
  alias Core.EsFixture.UserID

  defmodule Payload do
    @moduledoc "Нагрузка `Opened`."

    @enforce_keys ~w(name)a
    defstruct @enforce_keys

    @type t :: %__MODULE__{name: Account.Name.t()}

    @doc "Собрать нагрузку."
    @spec new(Account.Name.t()) :: t()

    def new(%Account.Name{} = name), do: %__MODULE__{name: name}
  end

  use Core.Es.Event,
    aggregate_id: Account.ID,
    by: UserID,
    payload: Payload
end
