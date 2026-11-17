defmodule Core.EsFixture.Itinerary.Event.StepRecorded do
  @moduledoc "Шаг записан отдельным событием — нагрузка-сущность с ПДн-местами."

  use Core.Es.Event,
    family: Core.EsFixture.Itinerary.Event,
    payload: Core.EsFixture.Itinerary.Step
end
