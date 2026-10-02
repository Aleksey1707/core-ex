defmodule Consumer.Domain.Sales.Activity.Client.Usecases do
  @moduledoc "Ожидание read-модели активности по двум агрегатам: предупреждений быть не должно."

  alias Consumer.Domain.Sales.Account
  alias Consumer.Domain.Sales.Activity.Projection
  alias Consumer.Domain.Sales.Order
  alias Core.Error

  def await(%Account.ID{} = account_id, %Order.ID{} = order_id) do
    with :ok <- Projection.await(Account, account_id, 5_000),
         :ok <- Projection.await(Order, order_id, 5_000) do
      :ok
    else
      {:error, %Error{code: :projection_timeout}} -> :timeout
      {:error, %Error{} = error} -> {:error, error.code}
    end
  end
end
