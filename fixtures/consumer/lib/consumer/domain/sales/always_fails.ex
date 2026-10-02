defmodule Consumer.Domain.Sales.AlwaysFails do
  @moduledoc "Агрегат, чей `decide/2` всегда возвращает ошибку: clause успеха в `execute/2` недостижима."

  alias Consumer.Domain.Sales.Order.Cmd
  alias Consumer.Domain.Sales.Order.Errors
  alias Consumer.Domain.Sales.Order.Event

  use Core.Es.Aggregate,
    event_codec: Consumer.Domain.Sales.Order.Event.Codec

  defstruct id: nil, version: nil

  @impl true
  def decide(%Cmd.Place{}, %__MODULE__{}),
    do: {:error, Errors.domain(__MODULE__, :already_exists, nil)}

  @impl true
  def evolve(state, %Event.Placed{}), do: state
  def evolve(state, %Event.Cancelled{}), do: state
end
