defmodule Consumer.Domain.Sales.Common.Order.Status do
  use Core.Enum,
    name: "Статус заказа",
    values: ~w(placed cancelled)a
end
