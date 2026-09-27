defmodule Consumer.Domain.Sales.Client.Usecases.Order do
  @moduledoc "Типовые вызовы генерируемых функций заказа и его репозитория: предупреждений быть не должно."

  alias Consumer.DAO
  alias Consumer.Domain.Sales.Common.Order
  alias Core.Context
  alias Core.Helper.Transact

  require Core.Config

  @repo Core.Config.repo!(Order.Repo)

  def place(%Order.ID{} = id, %Order.Cmd.Place{} = command, %Context{} = context) do
    Transact.run(DAO, fn ->
      with {:ok, order} <- @repo.get(id, :current, context),
           {:ok, {events, _order}} <- Order.execute(order, command) do
        @repo.append(events, context)
      end
    end)
  end
end
