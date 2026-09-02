defmodule Core.Helper.AfterCommitTest do
  use Core.DataCase, async: true

  import ExUnit.CaptureLog

  alias Core.Helper.AfterCommit

  test "вне TX — callback сразу" do
    parent = self()

    assert :ok = AfterCommit.register(fn -> send(parent, :ran) end)
    assert_received :ran
  end

  test "внутри TX — после успешного commit" do
    parent = self()

    assert {:ok, :ok} =
             TestRepo.transact(fn ->
               :ok = AfterCommit.register(fn -> send(parent, :ran) end)
               refute_received :ran
               {:ok, :ok}
             end)

    assert_received :ran
  end

  test "rollback — callback не вызывается" do
    parent = self()

    assert {:error, :boom} =
             TestRepo.transact(fn ->
               :ok = AfterCommit.register(fn -> send(parent, :ran) end)
               TestRepo.rollback(:boom)
             end)

    refute_received :ran
  end

  test "хук, открывший свою транзакцию, — его хуки тоже выполняются" do
    parent = self()

    assert {:ok, :ok} =
             TestRepo.transact(fn ->
               :ok =
                 AfterCommit.register(fn ->
                   send(parent, :outer)

                   {:ok, :inner} =
                     TestRepo.transact(fn ->
                       :ok = AfterCommit.register(fn -> send(parent, :inner) end)
                       {:ok, :inner}
                     end)
                 end)

               {:ok, :ok}
             end)

    assert_received :outer
    assert_received :inner
  end

  test "падение хука не отменяет остальные и не ломает результат transact" do
    parent = self()

    log =
      capture_log(fn ->
        assert {:ok, :ok} =
                 TestRepo.transact(fn ->
                   :ok = AfterCommit.register(fn -> raise "boom" end)
                   :ok = AfterCommit.register(fn -> send(parent, :second) end)
                   {:ok, :ok}
                 end)
      end)

    assert_received :second
    assert log =~ "Хук after-commit упал"
  end

  test "вложенный transact — хук после outermost commit" do
    parent = self()

    assert {:ok, :ok} =
             TestRepo.transact(fn ->
               assert {:ok, :inner} =
                        TestRepo.transact(fn ->
                          :ok = AfterCommit.register(fn -> send(parent, :ran) end)
                          {:ok, :inner}
                        end)

               refute_received :ran
               {:ok, :ok}
             end)

    assert_received :ran
  end
end
