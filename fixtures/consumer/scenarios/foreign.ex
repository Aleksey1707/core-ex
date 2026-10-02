defmodule Consumer.Foreign do
  @moduledoc "Граница вне контекста: `Sales` для неё — только его `exports`."

  use Boundary,
    deps: [Consumer.Domain.Sales]

  alias Consumer.Domain.Sales.Account
  alias Core.Context

  # Репозиторий счёта контекст не экспортирует: чужая граница пишет и читает счёт его usecases.
  def unexported_repo(%Account.ID{} = id, %Context{} = context),
    # expect: forbidden reference to Consumer.Domain.Sales.Account.Repo.Pg
    do: Account.Repo.Pg.get(id, :current, context)
end
