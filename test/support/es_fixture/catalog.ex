defmodule Core.EsFixture.Catalog do
  @moduledoc """
  Event-sourced агрегат на событиях `Core.EventFixture` — второй вид агрегата с ключом в области
  `fixture.name`: путь каталога — составной ключ `Core.EsFixture.Catalog.PathKey`.
  """

  alias Core.Es
  alias Core.EsFixture.Catalog.Cmd
  alias Core.EventFixture.AggID
  alias Core.EventFixture.Event
  alias Core.EventFixture.Name
  alias Core.Version

  use Core.Es.Aggregate,
    event_codec: Core.EventFixture.Event.Codec

  defstruct id: nil, version: nil, path: nil, closed?: false

  @type t :: %__MODULE__{
          id: AggID.t() | nil,
          version: Version.t() | nil,
          path: Name.t() | nil,
          closed?: boolean()
        }

  # ===== decide =====

  @doc "Решение по команде каталога."
  @spec decide(Cmd.t(), t()) :: {:ok, [Es.Aggregate.result()]}

  @impl true
  def decide(%Cmd.Create{path: path}, %__MODULE__{}), do: {:ok, [Event.Created.draft(Event.Created.Payload.new(path))]}

  # ===== evolve =====

  @doc "Применение события каталога."
  @spec evolve(t(), Event.t()) :: t()

  @impl true
  def evolve(state, %Event.Created{payload: payload}), do: %{state | path: payload.name}

  def evolve(state, %Event.Closed{}), do: %{state | closed?: true}
end
