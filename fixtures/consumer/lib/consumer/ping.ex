defmodule Consumer.Ping do
  @moduledoc "Агрегат, у кодека которого нет событий с нагрузкой."

  alias Consumer.Ping.Cmd
  alias Consumer.Ping.Event

  use Core.Es.Aggregate,
    event_codec: Consumer.Ping.Event.Codec

  defmodule ID do
    use Core.Prim.UUID,
      name: "Пинг",
      version: 7
  end

  defstruct id: nil, version: nil, count: 0

  @impl true
  def decide(%Cmd.Hit{}, %__MODULE__{}), do: {:ok, [Event.Pinged.draft()]}

  @impl true
  def evolve(%__MODULE__{} = state, %Event.Pinged{}), do: %{state | count: state.count + 1}
  def evolve(state, %Event.Ponged{}), do: state
end
