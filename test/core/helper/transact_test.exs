defmodule Core.Helper.TransactTest do
  use Core.DataCase, async: true

  import ExUnit.CaptureLog

  alias Core.Helper.Transact

  describe "run/3" do
    test "голое :ok остаётся :ok" do
      assert :ok = Transact.run(TestRepo, fn -> :ok end)
    end

    test "{:ok, value} проходит насквозь" do
      assert {:ok, 42} = Transact.run(TestRepo, fn -> {:ok, 42} end)
    end

    test "{:error, reason} откатывает и возвращается наружу" do
      assert {:error, :nope} = Transact.run(TestRepo, fn -> {:error, :nope} end)
    end
  end

  describe "warn_in_transaction/1" do
    test "вне транзакции молчит" do
      log = capture_log(fn -> assert :ok = Transact.warn_in_transaction("внешний вызов") end)

      refute log =~ "внутри транзакции"
    end

    test "внутри транзакции пишет error" do
      log =
        capture_log(fn ->
          Transact.run(TestRepo, fn ->
            Transact.warn_in_transaction("mts omni POST /send")
            :ok
          end)
        end)

      assert log =~ "внешний вызов внутри транзакции: mts omni POST /send"
    end
  end
end
