defmodule Core.EventFixture.Event.Created do
  @moduledoc "Агрегат создан."

  alias Core.EventFixture.ActorID
  alias Core.EventFixture.AggID

  defmodule Payload do
    @moduledoc "Нагрузка `Created`."

    alias Core.EventFixture.Name

    @enforce_keys ~w(name)a
    defstruct @enforce_keys

    @type t :: %__MODULE__{name: Name.t()}

    @doc "Собрать нагрузку."
    @spec new(Name.t()) :: t()

    def new(%Name{} = name), do: %__MODULE__{name: name}
  end

  use Core.Es.Event,
    aggregate_id: AggID,
    by: ActorID,
    payload: Payload
end
