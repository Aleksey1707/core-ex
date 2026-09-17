defmodule Blind.BadEvolve do
  alias Blind.Account.Cmd
  alias Blind.Account.Event

  use Core.Es.Aggregate,
    event_codec: Blind.Account.Event.Codec

  defstruct id: nil, version: nil, name: nil, status: nil

  @impl true
  def decide(%Cmd.Close{}, %__MODULE__{}), do: {:ok, [Event.Closed]}
  def decide(%Cmd.Rename{name: name}, %__MODULE__{}),
    do: {:ok, [{Event.Renamed, Event.Renamed.Payload.new(name)}]}

  # C2b — опечатка в поле нагрузки, нагрузка сопоставлена с %Payload{}
  @impl true
  def evolve(state, %Event.Opened{payload: %Event.Opened.Payload{} = payload}),
    do: %{state | name: payload.nmae}

  # C2a — опечатка в поле нагрузки
  def evolve(state, %Event.Renamed{payload: payload}), do: %{state | name: payload.nmae}

  # C1 — нет clause для Event.Closed
end

defmodule Blind.BadEvolveState do
  alias Blind.Account.Cmd
  alias Blind.Account.Event

  use Core.Es.Aggregate,
    event_codec: Blind.Account.Event.Codec

  defstruct id: nil, version: nil, name: nil, status: nil

  @impl true
  def decide(%Cmd.Rename{name: name}, %__MODULE__{}),
    do: {:ok, [{Event.Renamed, Event.Renamed.Payload.new(name)}]}

  # C4 — опечатка в ключе обновления состояния
  @impl true
  def evolve(state, %Event.Renamed{payload: payload}), do: %{state | nmae: payload.name}
  def evolve(state, %Event.Opened{}), do: state
  def evolve(state, %Event.Closed{}), do: state
end

defmodule Blind.S.Evolve do
  alias Blind.Account
  alias Blind.BadEvolve
  alias Blind.BadEvolveState
  alias Core.Es

  # C1 — свёртка события без clause evolve
  def c1_fold_missing_clause(%BadEvolve{} = state, %Account.Event.Closed{} = event),
    do: BadEvolve.fold(state, [event])

  def c1_execute_missing_clause(%BadEvolve{} = state, %Account.Cmd.Close{} = cmd),
    do: BadEvolve.execute(state, cmd)

  # C1 прямым вызовом evolve/2
  def c1_direct_evolve(%BadEvolve{} = state, %Account.Event.Closed{} = event),
    do: BadEvolve.evolve(state, event)

  # C2a через execute
  def c2a_execute_payload_typo(%BadEvolve{} = state, %Account.Cmd.Rename{} = cmd),
    do: BadEvolve.execute(state, cmd)

  # C3 — Agg.fold(state, ["bad"])
  def c3_fold_bad(%Account{} = state), do: Account.fold(state, ["bad"])

  # C3 прямым вызовом evolve/2
  def c3_direct_evolve_bad(%Account{} = state), do: Account.evolve(state, "bad")

  # C4 через execute и прямым вызовом
  def c4_execute_state_key_typo(%BadEvolveState{} = state, %Account.Cmd.Rename{} = cmd),
    do: BadEvolveState.execute(state, cmd)

  def c4_direct_state_key_typo(
        %BadEvolveState{} = state,
        %Account.Event.Renamed.Payload{} = payload,
        %Account.ID{} = id,
        %Blind.UserID{} = by,
        %Es.Event.At{} = at
      ) do
    event = Account.Event.Renamed.new(payload, id, Core.Version.new(), by, at)
    BadEvolveState.evolve(state, event)
  end
end
