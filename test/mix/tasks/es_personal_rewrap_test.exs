defmodule Mix.Tasks.Es.Personal.RewrapTest do
  # Тесты правят app env встроенного хранилища ключей: его читают все тесты с ПДн.
  use Core.DataCase, async: false

  import ExUnit.CaptureIO

  alias Core.Es.Personal.KeyStore.Pg
  alias Mix.Tasks.Es.Personal.Rewrap

  @new_kek Base.encode64(:binary.copy(<<7>>, 32))

  setup do
    saved = Application.get_env(:core, Pg)
    on_exit(fn -> Application.put_env(:core, Pg, saved) end)

    %{env: saved}
  end

  test "--batch-size разбирается в опции rewrap/1" do
    assert Rewrap.parse_opts!(["--batch-size", "2"]) == [batch_size: 2]
    assert Rewrap.parse_opts!([]) == []
  end

  test "--batch-size не положительное целое — ошибка" do
    assert_raise Mix.Error, ~r/--batch-size/, fn -> Rewrap.parse_opts!(["--batch-size", "0"]) end
  end

  test "run печатает статус до и после и прогресс после каждой пачки", %{env: env} do
    {:ok, _sealed} = Pg.seal(for _n <- 1..3, do: {Ecto.UUID.generate(), "aad", "Иван"})
    keks = Map.put(Map.new(Keyword.fetch!(env, :keks)), 2, @new_kek)
    Application.put_env(:core, Pg, Keyword.merge(env, keks: keks, current_kek: 2))
    {:ok, %{1 => old, 2 => current}} = Pg.status()

    output = capture_io(fn -> Rewrap.run(["--batch-size", "2"]) end)

    assert output =~ "KEK 1: #{old}\nKEK 2: #{current}\nперевёрнуто: 2\n"
    assert output =~ "\nПеревёрнуто ключей: #{old}\nKEK 1: 0\nKEK 2: #{old + current}\n"
  end

  test "обрыв перевёртки — Mix.Error с кодом ошибки", %{env: env} do
    {:ok, _sealed} = Pg.seal([{Ecto.UUID.generate(), "aad", "Иван"}])
    Application.put_env(:core, Pg, Keyword.merge(env, keks: %{2 => @new_kek}, current_kek: 2))

    assert_raise Mix.Error, ~r/перевёртка прервана: key_store\/kek_unknown/, fn ->
      capture_io(fn -> Rewrap.run([]) end)
    end
  end
end
