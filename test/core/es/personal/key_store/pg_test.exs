defmodule Core.Es.Personal.KeyStore.PgTest do
  use Core.DataCase, async: true

  alias Core.Error
  alias Core.Es.Personal.KeyStore.Pg
  alias Core.Es.Personal.Port
  alias Core.PersonalGoldenFixture
  alias Core.TestRepo

  # Golden схемы `1`: строка ключа и `$pd` записаны под KEK версии 1 из `config/test.exs` вне
  # реализации — `:crypto` по описанию схемы; открытый текст — JSON wire-значения поля. Константы —
  # `Core.PersonalGoldenFixture`.
  @golden_index "62883963d365744d5388c0bd3eae4a5cb739ec6af5389df7ff86e6e114f5a1ef"

  describe "golden схемы 1" do
    test "строка ключа и $pd под KEK фикстуры расшифровываются в известный текст" do
      :ok = PersonalGoldenFixture.put!(Ecto.UUID.generate())

      aad = Port.address([PersonalGoldenFixture.event_id(), "holder"])

      assert {:ok, [{:ok, ~s("Иван Петров")}]} = Pg.open([{Base.decode64!(PersonalGoldenFixture.pd()), aad}])
    end

    test "индекс фиксированных области и частей — фиксированный hex" do
      assert {:ok, [@golden_index]} = Pg.index([{"fixture.holder", ["Иван Петров", "1"]}])
    end
  end

  describe "сбой хранилища" do
    test "хранилище не ответило — :unavailable на всю пачку" do
      TestRepo.query!("SET LOCAL search_path TO no_such_schema")

      assert {:error, %Error{kind: :app, ns: :key_store, code: :unavailable}} =
               Pg.seal([{Ecto.UUID.generate(), "aad", "Иван"}])
    end

    test "версии KEK нет в конфигурации — :kek_unknown на всю пачку" do
      [gone, live] = [Ecto.UUID.generate(), Ecto.UUID.generate()]
      {:ok, [sealed_gone, sealed_live]} = Pg.seal([{gone, "aad", "Иван"}, {live, "aad", "Пётр"}])
      :ok = Pg.destroy(gone)

      TestRepo.query!("UPDATE es_subject_keys SET kek_version = 99 WHERE subject = ANY($1)", [[gone, live]])

      assert {:error, %Error{kind: :app, ns: :key_store, code: :kek_unknown, detail: %{kek_version: 99}}} =
               Pg.open([{sealed_live, "aad"}])

      assert {:ok, [:destroyed]} = Pg.open([{sealed_gone, "aad"}])
    end
  end

  describe "транзакция вызывающего" do
    test "откат убирает ключ: шифротекст становится нечитаемым" do
      subject = Ecto.UUID.generate()

      {:error, sealed} =
        TestRepo.transaction(fn ->
          {:ok, [sealed]} = Pg.seal([{subject, "aad", "Иван"}])
          TestRepo.rollback(sealed)
        end)

      assert {:ok, [:unreadable]} = Pg.open([{sealed, "aad"}])
      assert {:ok, [_sealed]} = Pg.seal([{subject, "aad", "Иван"}])
    end
  end

  describe "уничтожение" do
    test "повтор сохраняет первую дату уничтожения" do
      subject = Ecto.UUID.generate()
      :ok = Pg.destroy(subject)
      first = destroyed_at(subject)

      :ok = Pg.destroy(subject)

      assert destroyed_at(subject) == first
    end
  end

  # ---

  defp destroyed_at(subject) do
    %{rows: [[at]]} = TestRepo.query!("SELECT destroyed_at FROM es_subject_keys WHERE subject = $1", [subject])
    at
  end
end
