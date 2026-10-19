defmodule Consumer.Domain.Sales.Activity.Client.Usecases do
  @moduledoc """
  Ожидание read-модели активности по двум агрегатам и до события версии заказа: предупреждений быть
  не должно.
  """

  alias Consumer.Domain.Sales.Account
  alias Consumer.Domain.Sales.Activity.Projection
  alias Consumer.Domain.Sales.Order
  alias Core.Error
  alias Core.Version

  def await(%Account.ID{} = account_id, %Order.ID{} = order_id) do
    with :ok <- Projection.await(Account, account_id, 5_000),
         :ok <- Projection.await(Order, order_id, 5_000) do
      :ok
    else
      {:error, %Error{code: :projection_timeout}} -> :timeout
      {:error, %Error{} = error} -> {:error, error.code}
    end
  end

  def await_order(%Order.ID{} = order_id, %Version{} = version) do
    case Projection.await(Order, order_id, version, 5_000) do
      :ok -> :projected
      {:error, %Error{code: code}} when code in ~w(projection_timeout projection_rebuilding)a -> :accepted
    end
  end
end
