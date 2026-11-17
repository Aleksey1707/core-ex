defmodule Consumer.Domain.Sales.Itinerary.Event.Planned do
  @moduledoc "Маршрут спланирован: шаги с открытой частью и ПДн-местами."

  alias Consumer.Domain.Sales.Itinerary

  defmodule Payload do
    @moduledoc "Нагрузка `Planned` — список шагов; тип чтения шага допускает уничтоженное значение."

    use Core.Es.Event.Payload,
      fields: [steps: [list: [entity: Consumer.Domain.Sales.Itinerary.Step]]]

    use Core.Labels.Fields, labels: [steps: "Шаги"]
  end

  use Core.Es.Event,
    family: Itinerary.Event,
    payload: Payload

  use Core.Labels.Event, title: "Маршрут спланирован"
end
