defmodule Consumer.S.Await do
  @moduledoc "`Projection.await/3`: агрегат, ID, результат."

  alias Consumer.Account
  alias Consumer.Order
  alias Consumer.Ping
  alias Consumer.Projection

  # G4 — ID другого агрегата
  def g4_foreign_id(%Order.ID{} = id),
    # expect: incompatible types given to Consumer.Projection.await/3
    do: Projection.await(Account, id, 100)

  # G4b — агрегат, чьих событий нет в `events:`
  def g4b_foreign_aggregate(%Ping.ID{} = id),
    # expect: incompatible types given to Consumer.Projection.await/3
    do: Projection.await(Ping, id, 100)

  # G4c — `{:ok, _}` по результату `await`
  def g4c_case_ok(%Account.ID{} = id) do
    case Projection.await(Account, id, 100) do
      :ok -> :ok
      # expect: the following clause will never match
      {:ok, _} -> :ok
      {:error, _error} -> :error
    end
  end
end
