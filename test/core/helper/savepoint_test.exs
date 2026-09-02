defmodule Core.Helper.SavepointTest do
  use Core.DataCase, async: true

  alias Core.Helper.Savepoint

  test "успех — RELEASE, внешняя TX жива" do
    assert {:ok, :ok} =
             TestRepo.transact(fn ->
               assert :ok = Savepoint.run(TestRepo, fn -> :ok end)
               assert {:ok, %{rows: [[1]]}} = Ecto.Adapters.SQL.query(TestRepo, "SELECT 1", [])
               {:ok, :ok}
             end)
  end

  test "{:error, _} — откат savepoint, возвращает ошибку" do
    assert {:ok, {:error, :boom}} =
             TestRepo.transact(fn ->
               assert {:error, :boom} = Savepoint.run(TestRepo, fn -> {:error, :boom} end)
               assert {:ok, %{rows: [[1]]}} = Ecto.Adapters.SQL.query(TestRepo, "SELECT 1", [])
               {:ok, {:error, :boom}}
             end)
  end

  test "исключение — откат savepoint и пробрасывает исходное" do
    assert {:ok, :reraised} =
             TestRepo.transact(fn ->
               assert_raise RuntimeError, "boom", fn ->
                 Savepoint.run(TestRepo, fn -> raise "boom" end)
               end

               assert {:ok, %{rows: [[1]]}} = Ecto.Adapters.SQL.query(TestRepo, "SELECT 1", [])
               {:ok, :reraised}
             end)
  end
end
