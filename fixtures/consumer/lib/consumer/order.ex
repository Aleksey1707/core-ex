defmodule Consumer.Order do
  alias Consumer.Order.Errors
  alias Consumer.Order.Event
  alias Consumer.UserID
  alias Core.Es

  use Core.Es.Aggregate,
    event_codec: Consumer.Order.Event.Codec

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

  defmodule Cmd do
    defmodule Place do
      use Core.Es.Cmd

      @enforce_keys ~w(amount by at)a
      defstruct @enforce_keys

      @type t :: %__MODULE__{amount: Amount.t(), by: UserID.t(), at: Es.Event.At.t()}
    end

    defmodule Cancel do
      use Core.Es.Cmd

      @enforce_keys ~w(by at)a
      defstruct @enforce_keys
    end
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
end
