defmodule Consumer.DeliveryID do
  use Core.Prim.UUID,
    name: "Поставка",
    version: 5,
    namespace: Consumer.StreamID.namespace(),
    scope: "delivery"

  def from_number(number) when is_binary(number), do: from_key(number)
end
