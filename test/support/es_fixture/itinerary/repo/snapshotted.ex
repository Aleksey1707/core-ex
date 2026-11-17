defmodule Core.EsFixture.Itinerary.Repo.Snapshotted do
  @moduledoc """
  Write-behaviour маршрута со снапшотами — фикстура проверки вложенных ПДн-мест.

  Второй репозиторий одного агрегата — только тестовая фикстура: у агрегата репозиторий один
  (`docs/rules/13-repos.md`, «Write event-sourced агрегата (`use Core.Es.Aggregate.Repo.Pg`)»).
  """

  use Core.Es.Aggregate.Repo,
    aggregate: Core.EsFixture.Itinerary
end
