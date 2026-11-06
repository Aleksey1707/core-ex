defmodule Core.EsFixture.Account.AtVersion.ReadRepo.Pg do
  @moduledoc "Реализация чтения счёта на версии поверх write-репозитория."

  use Core.Es.Aggregate.ReadRepo.Pg,
    behaviour: Core.EsFixture.Account.AtVersion.ReadRepo,
    to_view: &Core.EsFixture.Account.AtVersion.View.from_state/1
end
