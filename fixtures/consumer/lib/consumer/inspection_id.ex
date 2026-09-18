defmodule Consumer.InspectionID do
  use Core.Prim.UUID,
    name: "Проверка позиции",
    version: 5,
    namespace: Consumer.StreamID.namespace(),
    scope: "item_inspection"

  def from_item(%Consumer.DeliveryID{} = delivery_id, item) when is_binary(item),
    do: from_key([Consumer.DeliveryID.value(delivery_id), item])
end
