defmodule Blind.BadEvolveMissing do
  alias Blind.Account.Cmd
  alias Blind.Account.Event

  use Core.Es.Aggregate,
    event_codec: Blind.Account.Event.Codec

  defstruct id: nil, version: nil, name: nil, status: nil

  @impl true
  def decide(%Cmd.Freeze{}, %__MODULE__{}), do: {:ok, [Event.Codec.draft(Event.Frozen)]}

  # C1 — нет clause для Event.Closed
  @impl true
  def evolve(state, %Event.Opened{payload: payload}), do: %{state | name: payload.name}
  def evolve(state, %Event.Renamed{payload: payload}), do: %{state | name: payload.name}
  def evolve(state, %Event.Frozen{}), do: %{state | status: :frozen}
end

defmodule Blind.BadEvolveMissing.Repo do
  # expect: incompatible types given to Blind.BadEvolveMissing.evolve/2
  use Core.Es.Aggregate.Repo,
    aggregate: Blind.BadEvolveMissing,
    id: Blind.Account.ID
end

defmodule Blind.BadEvolveTypo do
  alias Blind.Account.Cmd
  alias Blind.Account.Event

  use Core.Es.Aggregate,
    event_codec: Blind.Account.Event.Codec

  defstruct id: nil, version: nil, name: nil, status: nil

  @impl true
  def decide(%Cmd.Freeze{}, %__MODULE__{}), do: {:ok, [Event.Codec.draft(Event.Frozen)]}

  # C2a — опечатка в поле нагрузки без паттерна %Payload{}
  @impl true
  def evolve(state, %Event.Opened{payload: payload}), do: %{state | name: payload.nmae}
  def evolve(state, %Event.Renamed{payload: payload}), do: %{state | name: payload.name}
  def evolve(state, %Event.Frozen{}), do: %{state | status: :frozen}
  def evolve(state, %Event.Closed{}), do: %{state | status: :closed}
end

defmodule Blind.BadEvolveTypo.Repo do
  # expect: incompatible types given to Blind.BadEvolveTypo.evolve/2
  use Core.Es.Aggregate.Repo,
    aggregate: Blind.BadEvolveTypo,
    id: Blind.Account.ID
end

defmodule Blind.BadEvolveState do
  alias Blind.Account.Cmd
  alias Blind.Account.Event

  use Core.Es.Aggregate,
    event_codec: Blind.Account.Event.Codec

  defstruct id: nil, version: nil, name: nil, status: nil

  @impl true
  def decide(%Cmd.Freeze{}, %__MODULE__{}), do: {:ok, [Event.Codec.draft(Event.Frozen)]}

  # C4 — опечатка в ключе обновления состояния
  @impl true
  def evolve(state, %Event.Opened{payload: payload}), do: %{state | name: payload.name}
  def evolve(state, %Event.Renamed{payload: payload}), do: %{state | nmae: payload.name}
  def evolve(state, %Event.Frozen{}), do: %{state | status: :frozen}
  def evolve(state, %Event.Closed{}), do: %{state | status: :closed}
end

defmodule Blind.BadEvolveState.Repo do
  # expect: incompatible types given to Blind.BadEvolveState.evolve/2
  use Core.Es.Aggregate.Repo,
    aggregate: Blind.BadEvolveState,
    id: Blind.Account.ID
end
