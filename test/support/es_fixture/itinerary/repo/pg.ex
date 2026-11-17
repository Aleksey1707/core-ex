defmodule Core.EsFixture.Itinerary.Repo.Pg do
  @moduledoc "Write-репозиторий маршрута."

  use Core.Es.Aggregate.Repo.Pg,
    behaviour: Core.EsFixture.Itinerary.Repo,
    errors: Core.EsFixture.Itinerary.Errors,
    outbox: Core.EsFixture.Itinerary.Outbox
end
