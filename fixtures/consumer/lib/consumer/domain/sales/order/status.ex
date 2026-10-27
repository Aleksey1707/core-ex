defmodule Consumer.Domain.Sales.Order.Status do
  @moduledoc """
  Статус заказа

  | Значение | Описание |
  |---|---|
  | `:placed` | заказ оформлен |
  | `:cancelled` | заказ отменён |
  """

  use Core.Enum,
    name: "Статус заказа",
    values: ~w(placed cancelled)a

  use Core.Labels.Values,
    labels: [
      placed: "Оформлен",
      cancelled: "Отменён"
    ]
end
