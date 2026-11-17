defmodule Core.EsFixture.Itinerary.Event.RecipientChanged do
  @moduledoc "Получатель маршрута изменён — нагрузка-Prim с ПДн на корневом месте."

  use Core.Es.Event,
    family: Core.EsFixture.Itinerary.Event,
    payload: Core.EsFixture.Itinerary.Recipient
end
