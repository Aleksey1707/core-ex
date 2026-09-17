defmodule Consumer.Ping do
  @moduledoc "Агрегат, у кодека которого нет событий с нагрузкой."

  alias Consumer.Ping.Event

  use Core.Es.Aggregate,
    event_codec: Consumer.Ping.Event.Codec

  defmodule ID do
    use Core.Prim.UUID,
      name: "Пинг",
      version: 7
  end

  defmodule Cmd.Hit do
    use Core.Es.Cmd

    @enforce_keys ~w(by at)a
    defstruct @enforce_keys
  end

  defstruct id: nil, version: nil, count: 0

  @impl true
  def decide(%Cmd.Hit{}, %__MODULE__{}), do: {:ok, [Event.Codec.draft(Event.Pinged)]}

  @impl true
  def evolve(%__MODULE__{} = state, %Event.Pinged{}), do: %{state | count: state.count + 1}
  def evolve(state, %Event.Ponged{}), do: state
end
