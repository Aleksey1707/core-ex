defmodule Consumer.Domain.Sales.Common.Order do
  import Core.Guard, only: [is_enum: 2]

  alias Consumer.Domain.Sales.Common.Order.Cmd
  alias Consumer.Domain.Sales.Common.Order.Errors
  alias Consumer.Domain.Sales.Common.Order.Event
  alias Consumer.Domain.Sales.Common.Order.Status

  use Core.Es.Aggregate,
    event_codec: Consumer.Domain.Sales.Common.Order.Event.Codec

  defmodule ID do
    use Core.Prim.UUID,
      name: "Заказ",
      version: 7
  end

  defmodule Amount do
    use Core.Prim.Integer,
      name: "Сумма",
      min: 1
  end

  defstruct id: nil, version: nil, amount: nil, cancelled?: false

  @impl true
  def decide(%Cmd.Place{amount: amount}, %__MODULE__{version: nil}),
    do: {:ok, [Event.Placed.draft(Event.Placed.Payload.new(amount))]}

  def decide(%Cmd.Place{}, %__MODULE__{}),
    do: {:error, Errors.domain(__MODULE__, :already_exists, nil)}

  def decide(%Cmd.Cancel{}, %__MODULE__{version: nil}),
    do: {:error, Errors.domain(__MODULE__, :not_found, nil)}

  def decide(%Cmd.Cancel{}, %__MODULE__{}), do: {:ok, [Event.Cancelled.draft()]}

  @impl true
  def evolve(state, %Event.Placed{payload: %Event.Placed.Payload{} = payload}),
    do: %{state | amount: payload.amount}

  def evolve(state, %Event.Cancelled{}), do: %{state | cancelled?: true}

  def status(%__MODULE__{cancelled?: true}), do: :cancelled
  def status(%__MODULE__{}), do: :placed

  def status?(%__MODULE__{} = state, status) when is_enum(status, Status),
    do: status(state) == status
end
