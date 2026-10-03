defmodule Core.Helper.LockTest do
  use Core.DataCase, async: false

  alias Core.Helper
  alias Ecto.Adapters.SQL.Sandbox

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

  describe "with_advisory!/4" do
    test "держит блокировку через несколько транзакций и снимает её после" do
      key = @key + 3

      assert :done =
               Sandbox.unboxed_run(TestRepo, fn ->
                 Helper.Lock.with_advisory!(TestRepo, key, fn ->
                   {:ok, _} = TestRepo.transact(fn -> {:ok, :first} end)
                   {:ok, _} = TestRepo.transact(fn -> {:ok, :second} end)
                   refute free?(key)
                   :done
                 end)
               end)

      assert free?(key)
    end

    test "снимает блокировку при исключении в колбэке" do
      key = @key + 4

      assert_raise RuntimeError, "сбой", fn ->
        Sandbox.unboxed_run(TestRepo, fn ->
          Helper.Lock.with_advisory!(TestRepo, key, fn -> raise "сбой" end)
        end)
      end

      assert free?(key)
    end

    test "сбрасывает lock_timeout сессии после взятия" do
      assert "0" =
               Sandbox.unboxed_run(TestRepo, fn ->
                 Helper.Lock.with_advisory!(TestRepo, @key + 5, fn -> show_lock_timeout() end, lock_timeout: "250ms")
               end)
    end

    test "отказывает внутри транзакции" do
      assert_raise ArgumentError, ~r/внутри транзакции/, fn ->
        TestRepo.transact(fn -> Helper.Lock.with_advisory!(TestRepo, @key + 6, fn -> :ok end) end)
      end
    end
  end

  defp free?(key) do
    {:ok, free} = Task.async(fn -> Sandbox.unboxed_run(TestRepo, fn -> try_lock(key) end) end) |> Task.await()
    free
  end

  defp try_lock(key), do: TestRepo.transact(fn -> {:ok, Helper.Lock.try_advisory_xact(TestRepo, key)} end)

  defp show_lock_timeout do
    %{rows: [[value]]} = Ecto.Adapters.SQL.query!(TestRepo, "SHOW lock_timeout", [])
    value
  end
end
