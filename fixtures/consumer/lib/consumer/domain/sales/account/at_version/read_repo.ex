defmodule Consumer.Domain.Sales.Account.AtVersion.ReadRepo do
  @moduledoc """
  Чтение счёта на версии — read-модель по назначению над event-sourced агрегатом.

  Адрес версии — `%Account.ID{}` и `%Core.Version{}`; наружу уходит только `AtVersion.View`.
  """

  use Core.Es.Aggregate.ReadRepo,
    repo: Consumer.Domain.Sales.Account.Repo,
    view: Consumer.Domain.Sales.Account.AtVersion.View
end
