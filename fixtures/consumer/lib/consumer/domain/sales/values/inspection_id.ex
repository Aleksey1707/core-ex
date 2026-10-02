defmodule Consumer.Domain.Sales.Values.InspectionID do
  alias Consumer.Domain.Sales.Values.DeliveryID

  use Core.Prim.UUID,
    name: "Проверка позиции",
    version: 5,
    namespace: Consumer.Infra.StreamID.namespace(),
    scope: "item_inspection"

  def from_item(%DeliveryID{} = delivery_id, item) when is_binary(item),
    do: from_key([DeliveryID.value(delivery_id), item])
end
