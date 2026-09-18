defmodule Core.EsFixture.Catalog.Repo.Pg do
  @moduledoc "Write-репозиторий каталога с резервом пути `Core.EsFixture.Catalog.PathKey`."

  alias Core.EsFixture.Catalog
  alias Core.EventFixture

  use Core.Es.Aggregate.Repo.Pg,
    behaviour: Core.EsFixture.Catalog.Repo,
    aggregate: Catalog,
    id: EventFixture.AggID,
    errors: EventFixture.Errors,
    outbox: Core.StateStoredFixture.Outbox,
    key_reservations: [Catalog.PathKey]
end
