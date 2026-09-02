defmodule Core.Helper.LockTest do
  use Core.DataCase, async: false

  alias Core.Helper

  @key 918_273_645

  test "advisory_xact! берёт блокировку внутри транзакции" do
    assert {:ok, :ok} =
             TestRepo.transact(fn ->
               assert :ok = Helper.Lock.advisory_xact!(TestRepo, @key)
               {:ok, :ok}
             end)
  end

  test "try_advisory_xact сообщает, свободна ли блокировка" do
    assert {:ok, true} =
             TestRepo.transact(fn ->
               {:ok, Helper.Lock.try_advisory_xact(TestRepo, @key + 1)}
             end)
  end

  test "advisory_xact! выставляет lock_timeout на транзакцию" do
    assert {:ok, "250ms"} =
             TestRepo.transact(fn ->
               :ok = Helper.Lock.advisory_xact!(TestRepo, @key + 2, lock_timeout: "250ms")
               %{rows: [[value]]} = Ecto.Adapters.SQL.query!(TestRepo, "SHOW lock_timeout", [])
               {:ok, value}
             end)
  end
end
