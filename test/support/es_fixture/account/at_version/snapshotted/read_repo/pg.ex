defmodule Core.EsFixture.Account.AtVersion.Snapshotted.ReadRepo.Pg do
  @moduledoc "Реализация чтения счёта на версии поверх write-репозитория со снапшотами."

  use Core.Es.Aggregate.ReadRepo.Pg,
    behaviour: Core.EsFixture.Account.AtVersion.Snapshotted.ReadRepo,
    to_view: &Core.EsFixture.Account.AtVersion.View.from_state/1
end
