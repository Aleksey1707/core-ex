defmodule Consumer.Domain.Sales.Order.Status do
  use Core.Enum,
    name: "Статус заказа",
    values: ~w(placed cancelled)a

  use Core.Labels.Values,
    labels: [
      placed: "Оформлен",
      cancelled: "Отменён"
    ]
end
