defmodule Consumer.Domain.Sales.Itinerary.Step do
  @moduledoc """
  Шаг маршрута: открытые канал, статус и попытки рядом с ПДн-местами получателя и контента.

  Одна декларация даёт два типа: `t()` — чтение, с `%Core.Es.Personal.Destroyed{}` на местах, и
  `write_t()` — запись, без уничтоженного значения.
  """

  alias Consumer.Domain.Sales.Itinerary
  alias Consumer.Domain.Sales.Itinerary.Step

  use Core.Struct,
    fields: [
      channel: [enum: Itinerary.Channel],
      status: [enum: Itinerary.Status],
      attempts: [type: :non_neg_integer],
      recipient: [prim: Itinerary.Recipient],
      content: [prim: Itinerary.Content]
    ]

  use Core.Labels.Fields,
    labels: [
      channel: "Канал",
      status: "Статус",
      attempts: "Попытки",
      recipient: "Получатель",
      content: "Содержимое"
    ]

  defmodule Codec do
    @moduledoc "Плагин шага — из его общей декларации."

    use Core.Codec.Plugin, types: [Step]
  end
end
