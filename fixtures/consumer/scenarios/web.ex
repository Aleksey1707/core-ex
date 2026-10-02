defmodule ConsumerWeb do
  @moduledoc """
  Граница web: `DAO` ей недоступен, а контекст — только его `exports`. `check: [aliases: true]` —
  ссылка на модуль значением проверяется наравне с вызовом.
  """

  use Boundary,
    deps: [Consumer.Domain.Sales],
    check: [aliases: true]

  alias Consumer.Domain.Sales.Account
  alias Consumer.Infra.DAO
  alias Core.Context
  alias Core.Helper.Transact

  # Экспорт контекста — модуль usecases и тип ID: предупреждений быть не должно.
  def history(%Account.ID{} = id, limit, offset, %Context{} = context),
    do: Account.Client.Usecases.history(id, limit, offset, context)

  # `DAO`, переданный значением, а не вызовом: без `check: [aliases: true]` сборка его не видит
  def dao_by_value(fun) when is_function(fun, 0),
    # expect: forbidden reference to Consumer.Infra.DAO
    do: Transact.run(DAO, fun)
end
