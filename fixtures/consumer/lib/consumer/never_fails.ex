defmodule Consumer.NeverFails do
  @moduledoc "Агрегат, чей `decide/2` никогда не возвращает ошибку: clause ошибки в `execute/2` недостижима."

  alias Consumer.Order.Cmd
  alias Consumer.Order.Event

  use Core.Es.Aggregate,
    event_codec: Consumer.Order.Event.Codec

  defstruct id: nil, version: nil, cancelled?: false

  @impl true
  def decide(%Cmd.Cancel{}, %__MODULE__{cancelled?: true}), do: {:ok, []}
  def decide(%Cmd.Cancel{}, %__MODULE__{}), do: {:ok, [Event.Codec.draft(Event.Cancelled)]}

  @impl true
  def evolve(state, %Event.Placed{}), do: state
  def evolve(state, %Event.Cancelled{}), do: %{state | cancelled?: true}
end
