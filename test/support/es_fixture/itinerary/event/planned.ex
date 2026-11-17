defmodule Core.EsFixture.Itinerary.Event.Planned do
  @moduledoc "Маршрут спланирован: шаги с открытой частью и ПДн-местами."

  defmodule Payload do
    @moduledoc "Нагрузка `Planned` — список шагов; ПДн-места шага субъекта `:aggregate_id`."

    use Core.Es.Event.Payload,
      fields: [steps: [list: [entity: Core.EsFixture.Itinerary.Step]]]

    use Core.Labels.Fields, labels: [steps: "Шаги"]
  end

  use Core.Es.Event,
    family: Core.EsFixture.Itinerary.Event,
    payload: Payload

  use Core.Labels.Event, title: "Маршрут спланирован"
end
