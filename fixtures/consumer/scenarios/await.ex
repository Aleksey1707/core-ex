defmodule ConsumerTest.Await do
  @moduledoc "`Projection.await/3`: агрегат, ID, результат; ожидание в usecase с `wait:`."

  alias Consumer.Domain.Sales.Account
  alias Consumer.Domain.Sales.Order
  alias Consumer.Domain.Sales.Ping
  alias Consumer.Domain.Sales.Activity.Projection
  alias Core.Error

  # G4 — ID другого агрегата
  def g4_foreign_id(%Order.ID{} = id),
    # expect: incompatible types given to Consumer.Domain.Sales.Activity.Projection.await/3
    do: Projection.await(Account, id, 100)

  # G4b — агрегат, чьих событий нет в `events:`
  def g4b_foreign_aggregate(%Ping.ID{} = id),
    # expect: incompatible types given to Consumer.Domain.Sales.Activity.Projection.await/3
    do: Projection.await(Ping, id, 100)

  # G4o — прежняя форма: реализация ожидания в библиотеке вместо `await/3` модуля проекции
  # expect: Core.Es.Projection.await/4 is undefined or private
  def g4o_library_await(%Account.ID{} = id), do: Core.Es.Projection.await(Projection, Account, id, 100)

  # G4c — `{:ok, _}` по результату `await`
  def g4c_case_ok(%Account.ID{} = id) do
    case Projection.await(Account, id, 100) do
      :ok -> :ok
      # expect: the following clause will never match
      {:ok, _} -> :ok
      {:error, _error} -> :error
    end
  end

  # G4w — usecase заказа с `wait:`: хелпер ожидания скопирован у счёта, и агрегат в `await` — счёт
  def g4w_wait_foreign_aggregate(%Order.ID{} = id, opts),
    do: {:ok, {awaited(id, Keyword.get(opts, :wait, :none)), id}}

  # ---

  defp awaited(%Order.ID{}, :none), do: :accepted

  defp awaited(%Order.ID{} = id, timeout) when is_integer(timeout) do
    # expect: incompatible types given to Consumer.Domain.Sales.Activity.Projection.await/3
    case Projection.await(Account, id, timeout) do
      :ok -> :projected
      {:error, %Error{code: code}} when code in ~w(projection_timeout projection_rebuilding)a -> :accepted
    end
  end
end
