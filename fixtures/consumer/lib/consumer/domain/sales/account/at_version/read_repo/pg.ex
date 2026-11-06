defmodule Consumer.Domain.Sales.Account.AtVersion.ReadRepo.Pg do
  @moduledoc "Реализация чтения счёта на версии поверх write-репозитория."

  use Core.Es.Aggregate.ReadRepo.Pg,
    behaviour: Consumer.Domain.Sales.Account.AtVersion.ReadRepo,
    to_view: &Consumer.Domain.Sales.Account.AtVersion.View.from_state/1
end
