defmodule Consumer.Order.Event.Codec do
  alias Consumer.Order
  alias Consumer.Order.Event

  @tag_by_mod %{Event.Placed => "order.placed", Event.Cancelled => "order.cancelled"}

  use Core.Es.Event.Codec,
    event: Event,
    type: "order",
    tags: @tag_by_mod

  @impl true
  def dump_payload(%Event.Placed{payload: %Event.Placed.Payload{} = payload}, codec),
    do: %{"amount" => codec.dump(payload.amount)}

  @impl true
  def load_payload(Event.Placed, wire, codec) do
    with {:ok, amount} <- codec.load(Order.Amount, field(wire, :amount)) do
      {:ok, Event.Placed.Payload.new(amount)}
    end
  end
end
