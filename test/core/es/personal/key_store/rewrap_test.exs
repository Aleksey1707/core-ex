defmodule Core.Es.Personal.KeyStore.RewrapTest do
  # Тесты правят app env встроенного хранилища ключей: его читают все тесты с ПДн.
  use Core.DataCase, async: false

  alias Core.Error
  alias Core.Es.Personal.KeyStore.Pg

  @new_kek Base.encode64(:binary.copy(<<7>>, 32))

  setup do
    saved = Application.get_env(:core, Pg)
    on_exit(fn -> Application.put_env(:core, Pg, saved) end)

    %{env: saved}
  end

  describe "status/0" do
    test "живые ключи по версиям KEK, следы не в счёт", %{env: env} do
      {:ok, before} = Pg.status()
      {:ok, _sealed} = Pg.seal([{Ecto.UUID.generate(), "aad", "Иван"}, {Ecto.UUID.generate(), "aad", "Пётр"}])
      destroyed = Ecto.UUID.generate()
      {:ok, _sealed} = Pg.seal([{destroyed, "aad", "Анна"}])
      :ok = Pg.destroy(destroyed)
      :ok = Pg.destroy(Ecto.UUID.generate())

      rotate(env)

      assert {:ok, %{1 => live, 2 => 0}} = Pg.status()
      assert live == Map.fetch!(before, 1) + 2
    end
  end

  describe "rewrap/1" do
    test "переводит живые ключи на текущий KEK, шифротекст открывается", %{env: env} do
      [first, second] = [Ecto.UUID.generate(), Ecto.UUID.generate()]
      {:ok, [sealed_first, sealed_second]} = Pg.seal([{first, "aad", "Иван"}, {second, "aad", "Пётр"}])
      rotate(env)
      {:ok, %{1 => old, 2 => current}} = Pg.status()

      assert {:ok, ^old} = Pg.rewrap(batch_size: 1)

      assert {:ok, %{1 => 0, 2 => rewrapped}} = Pg.status()
      assert rewrapped == old + current

      drop_old(env)

      assert {:ok, [{:ok, "Иван"}, {:ok, "Пётр"}]} = Pg.open([{sealed_first, "aad"}, {sealed_second, "aad"}])
      assert {:ok, 0} = Pg.rewrap([])
    end

    test "прерванный прогон продолжается с места остановки", %{env: env} do
      {:ok, _sealed} = Pg.seal(for _n <- 1..3, do: {Ecto.UUID.generate(), "aad", "Иван"})
      rotate(env)
      {:ok, %{1 => old}} = Pg.status()

      assert catch_throw(Pg.rewrap(batch_size: 2, on_batch: fn count -> throw({:stopped, count}) end)) ==
               {:stopped, 2}

      assert {:ok, %{1 => left}} = Pg.status()
      assert left == old - 2
      assert {:ok, ^left} = Pg.rewrap([])
    end

    test "обрыв пачки откатывает её целиком", %{env: env} do
      [live, gone] = [Ecto.UUID.generate(), Ecto.UUID.generate()]
      {:ok, _sealed} = Pg.seal([{live, "aad", "Иван"}, {gone, "aad", "Пётр"}])
      TestRepo.query!("UPDATE es_subject_keys SET kek_version = 99 WHERE subject = $1", [gone])
      rotate(env)
      {:ok, before} = Pg.status()

      assert {:error, %Error{code: :kek_unknown, detail: %{kek_version: 99}}} = Pg.rewrap([])
      assert {:ok, ^before} = Pg.status()
    end

    test "неизвестная опция — ArgumentError" do
      assert_raise ArgumentError, ~r/^Core\.Es\.Personal\.KeyStore\.Pg\.rewrap\/1: unknown options \[:batch\]/, fn ->
        Pg.rewrap(batch: 1)
      end
    end

    test "внутри транзакции — ArgumentError", %{env: env} do
      rotate(env)

      assert_raise ArgumentError, ~r/внутри транзакции/, fn ->
        TestRepo.transaction(fn -> Pg.rewrap([]) end)
      end
    end

    test "старая версия удалена до перевёртки — :kek_unknown", %{env: env} do
      {:ok, [sealed]} = Pg.seal([{Ecto.UUID.generate(), "aad", "Иван"}])
      drop_old(env)

      assert {:error, %Error{kind: :app, ns: :key_store, code: :kek_unknown, detail: %{kek_version: 1}}} =
               Pg.rewrap([])

      assert {:error, %Error{code: :kek_unknown}} = Pg.open([{sealed, "aad"}])
    end
  end

  # ---

  defp rotate(env) do
    keks = Map.put(Map.new(Keyword.fetch!(env, :keks)), 2, @new_kek)
    Application.put_env(:core, Pg, Keyword.merge(env, keks: keks, current_kek: 2))
  end

  defp drop_old(env), do: Application.put_env(:core, Pg, Keyword.merge(env, keks: %{2 => @new_kek}, current_kek: 2))
end
