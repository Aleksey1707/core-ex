defmodule Blind.NeverFails do
  @moduledoc "Корректный агрегат, чей `decide/2` никогда не возвращает ошибку."

  alias Blind.Order.Cmd
  alias Blind.Order.Event

  use Core.Es.Aggregate,
    event_codec: Blind.Order.Event.Codec

  defstruct id: nil, version: nil, cancelled?: false

  @impl true
  def decide(%Cmd.Cancel{}, %__MODULE__{cancelled?: true}), do: {:ok, []}
  def decide(%Cmd.Cancel{}, %__MODULE__{}), do: {:ok, [Event.Codec.draft(Event.Cancelled)]}

  @impl true
  def evolve(state, %Event.Placed{}), do: state
  def evolve(state, %Event.Cancelled{}), do: %{state | cancelled?: true}
end

defmodule Blind.AlwaysFails do
  @moduledoc "Корректный агрегат, чей `decide/2` всегда возвращает ошибку."

  alias Blind.Order.Cmd
  alias Blind.Order.Errors
  alias Blind.Order.Event

  use Core.Es.Aggregate,
    event_codec: Blind.Order.Event.Codec

  defstruct id: nil, version: nil

  @impl true
  def decide(%Cmd.Place{}, %__MODULE__{}),
    do: {:error, Errors.domain(__MODULE__, :already_exists, nil)}

  @impl true
  def evolve(state, %Event.Placed{}), do: state
  def evolve(state, %Event.Cancelled{}), do: state
end
