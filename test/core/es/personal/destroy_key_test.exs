defmodule Core.Es.Personal.DestroyKeyTest do
  use Core.DataCase, async: true

  import ExUnit.CaptureLog

  alias Core.Config
  alias Core.Context
  alias Core.Error
  alias Core.Es.Personal
  alias Core.Es.Personal.ActorID
  alias Core.Es.Personal.Event.Codec
  alias Core.Es.Personal.Event.KeyDestroyed
  alias Core.Es.Personal.Port
  alias Core.Es.Personal.SubjectID
  alias Core.Es.Store
  alias Core.EsFixture.Account
  alias Core.EsFixture.UserID
  alias Core.Helper.Transact
  alias Core.Version

  describe "destroy_key/3" do
    test "ключ уничтожен, в поток субъекта записано событие уничтожения ключа" do
      subject = Account.ID.new()
      by = UserID.new()
      dumped = Config.codec().dump(subject)
      {:ok, [_sealed]} = Port.seal([{dumped, "aad", "Иван"}])

      assert :ok = Personal.destroy_key(subject, by, Context.new())

      assert {:error, %Error{code: :subject_destroyed}} = Port.seal([{dumped, "aad", "Пётр"}])
      subject_id = subject_id(subject)
      actor_id = ActorID.new!(UserID.value(by))

      assert [
               %KeyDestroyed{
                 aggregate_id: ^subject_id,
                 aggregate_version: %Version{value: 1},
                 by: ^actor_id,
                 payload: nil
               }
             ] = Store.Test.events!(Codec, subject_id)
    end

    test "повтор — :ok без второго события" do
      subject = Account.ID.new()
      by = UserID.new()

      :ok = Personal.destroy_key(subject, by, Context.new())

      log = capture_debug(fn -> assert :ok = Personal.destroy_key(subject, UserID.new(), Context.new()) end)

      assert [%KeyDestroyed{by: by_first}] = Store.Test.events!(Codec, subject_id(subject))
      assert by_first == ActorID.new!(UserID.value(by))
      assert log =~ "ключ субъекта уничтожен: subject_id=#{Account.ID.value(subject)} event_written=false"
    end

    test "субъект без ключа — след: запись ПДн отвергнута, событие записано" do
      subject = Account.ID.new()
      by = UserID.new()

      log = capture_debug(fn -> assert :ok = Personal.destroy_key(subject, by, Context.new()) end)

      assert {:error, %Error{kind: :domain, ns: :key_store, code: :subject_destroyed}} =
               Port.seal([{Config.codec().dump(subject), "aad", "Иван"}])

      assert [%KeyDestroyed{}] = Store.Test.events!(Codec, subject_id(subject))
      assert log =~ "ключ субъекта уничтожен: subject_id=#{Account.ID.value(subject)} event_written=true"
      refute log =~ UserID.value(by)
    end

    test "откат транзакции вызывающего убирает и след, и событие, лога нет" do
      subject = Account.ID.new()

      log =
        capture_debug(fn ->
          assert {:error, :rollback} =
                   Transact.run(TestRepo, fn ->
                     :ok = Personal.destroy_key(subject, UserID.new(), Context.new())
                     {:error, :rollback}
                   end)
        end)

      refute log =~ Account.ID.value(subject)

      assert {:ok, [_sealed]} = Port.seal([{Config.codec().dump(subject), "aad", "Иван"}])
      assert Store.Test.events!(Codec, subject_id(subject)) == []
    end
  end

  describe "Test.key_destroyed/2" do
    test "событие в той форме, в какой его пишет операция" do
      subject = Account.ID.new()
      by = UserID.new()
      :ok = Personal.destroy_key(subject, by, Context.new())
      [written] = Store.Test.events!(Codec, subject_id(subject))

      assert %KeyDestroyed{} = built = Personal.Test.key_destroyed(subject, by: by, at: written.at)
      assert %{built | id: written.id} == written
    end

    test "нет by: или at: — KeyError" do
      assert_raise KeyError, fn -> Personal.Test.key_destroyed(Account.ID.new(), by: UserID.new()) end
    end
  end

  defp subject_id(subject), do: SubjectID.new!(Account.ID.value(subject))

  # Уровень модуля глобален, но другие тесты логов `Core.Es.Personal` не проверяют, а субъекты
  # здесь уникальны.
  defp capture_debug(fun) do
    Logger.put_module_level(Personal, :debug)

    try do
      capture_log(fun)
    after
      Logger.delete_module_level(Personal)
    end
  end
end
