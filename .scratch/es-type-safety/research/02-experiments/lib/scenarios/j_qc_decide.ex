defmodule Blind.QcStyle do
  alias Blind.Account.Cmd
  alias Blind.Account.Event

  use Core.Es.Aggregate,
    event_codec: Blind.Account.Event.Codec

  defstruct id: nil, version: nil, name: nil, status: nil

  @mutations [Cmd.Rename, Cmd.Close]

  # J1 — стиль qc: %mod{} = cmd when mod in @mutations, опечатка в поле команды
  @impl true
  def decide(%mod{} = cmd, %__MODULE__{version: nil}) when mod in @mutations,
    do: {:error, cmd.nmae}

  # J2 — %Cmd.Rename{} = cmd, опечатка в поле команды
  def decide(%Cmd.Rename{} = cmd, %__MODULE__{}),
    do: {:ok, [{Event.Renamed, Event.Renamed.Payload.new(cmd.nmae)}]}

  def decide(%Cmd.Close{}, %__MODULE__{}), do: {:ok, [Event.Closed]}

  @impl true
  def evolve(state, %Event.Renamed{payload: payload}), do: %{state | name: payload.name}
  def evolve(state, %Event.Closed{}), do: %{state | status: :closed}
  def evolve(state, %Event.Opened{}), do: state
end

defmodule Blind.S.QcStyle do
  alias Blind.Account
  alias Blind.QcStyle

  def j1_execute(%QcStyle{} = state, %Account.Cmd.Close{} = cmd), do: QcStyle.execute(state, cmd)

  def j1_direct_close(%Account.Cmd.Close{} = cmd), do: QcStyle.decide(cmd, %QcStyle{version: nil})
end
