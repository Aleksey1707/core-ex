defmodule Core.DAOTest do
  use Core.DataCase, async: true

  alias Core.Helper.AfterCommit

  describe "transact/1" do
    test "хуки после commit" do
      parent = self()

      assert {:ok, :ok} =
               TestRepo.transact(fn ->
                 :ok = AfterCommit.register(fn -> send(parent, :ran) end)
                 refute_received :ran
                 {:ok, :ok}
               end)

      assert_received :ran
    end
  end

  describe "transaction/1" do
    test "хуки после commit" do
      parent = self()

      assert {:ok, :ok} =
               TestRepo.transaction(fn ->
                 :ok = AfterCommit.register(fn -> send(parent, :ran) end)
                 refute_received :ran
                 :ok
               end)

      assert_received :ran
    end

    test "rollback — хуки не выполняются" do
      parent = self()

      assert {:error, :boom} =
               TestRepo.transaction(fn ->
                 :ok = AfterCommit.register(fn -> send(parent, :ran) end)
                 TestRepo.rollback(:boom)
               end)

      refute_received :ran
    end

    test "callback с repo-аргументом проходит насквозь" do
      assert {:ok, TestRepo} = TestRepo.transaction(fn repo -> repo end)
    end
  end

  describe "смешанная вложенность" do
    test "transaction внутри transact — хуки после outermost commit" do
      parent = self()

      assert {:ok, :ok} =
               TestRepo.transact(fn ->
                 assert {:ok, :inner} =
                          TestRepo.transaction(fn ->
                            :ok = AfterCommit.register(fn -> send(parent, :ran) end)
                            :inner
                          end)

                 refute_received :ran
                 {:ok, :ok}
               end)

      assert_received :ran
    end
  end

  describe "опции" do
    test "отсутствие обязательного ключа — CompileError" do
      assert_raise CompileError, ~r/DAO: нет обязательных опций: \[:adapter\]/, fn ->
        Code.compile_string("""
        defmodule Core.DAOTest.NoAdapter do
          use Core.DAO, otp_app: :core
        end
        """)
      end
    end
  end
end
