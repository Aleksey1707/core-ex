defmodule Consumer.Domain.Sales.Values.DeliveryID do
  use Core.Prim.UUID,
    name: "Поставка",
    version: 5,
    namespace: Consumer.Infra.StreamID.namespace(),
    scope: "delivery"

  def from_number(number) when is_binary(number), do: from_key(number)
end
