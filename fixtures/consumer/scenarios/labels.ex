defmodule ConsumerTest.Labels do
  @moduledoc "Подпись значения вне Enum: голова `label/1` закрывает домен."

  alias Consumer.Domain.Sales.Order

  # значение, которого нет в Enum
  # expect: incompatible types given to Consumer.Domain.Sales.Order.Status.label/1
  def unknown_status_label, do: Order.Status.label(:shipped)
end
