defmodule Core.EsFixture.Itinerary.Repo.Snapshotted.Pg do
  @moduledoc """
  Write-репозиторий маршрута со снапшотами: снапшот пишется после двух свёрнутых событий.

  Второй репозиторий одного агрегата — только тестовая фикстура: у агрегата репозиторий один
  (`docs/rules/13-repos.md`, «Write event-sourced агрегата (`use Core.Es.Aggregate.Repo.Pg`)»).
  """

  alias Core.EsFixture.Itinerary

  use Core.Es.Aggregate.Repo.Pg,
    behaviour: Itinerary.Repo.Snapshotted,
    errors: Itinerary.Errors,
    outbox: Itinerary.Outbox,
    snapshot: [every: 2]
end
