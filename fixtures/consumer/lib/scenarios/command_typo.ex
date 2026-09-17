defmodule Consumer.S.CommandTypo do
  @moduledoc "Опечатка в поле команды, суженной `%Cmd.X{}` в голове `decide/2`."

  alias Consumer.Account.Cmd
  alias Consumer.Account.Event

  use Core.Es.Aggregate,
    event_codec: Consumer.Account.Event.Codec

  defstruct id: nil, version: nil, name: nil, status: nil

  # J2
  @impl true
  def decide(%Cmd.Rename{} = command, %__MODULE__{}),
    # expect: unknown key .nmae
    do: {:ok, [Event.Renamed.draft(Event.Renamed.Payload.new(command.nmae))]}

  @impl true
  def evolve(state, %Event.Opened{}), do: state
  def evolve(state, %Event.Renamed{}), do: state
  def evolve(state, %Event.Frozen{}), do: state
  def evolve(state, %Event.Closed{}), do: state
end
