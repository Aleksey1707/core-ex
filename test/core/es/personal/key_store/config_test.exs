defmodule Core.Es.Personal.KeyStore.ConfigTest do
  # Тесты правят app env встроенного хранилища ключей: его читают все тесты с ПДн.
  use ExUnit.Case, async: false

  alias Core.Es.Personal.KeyStore.Pg

  @kek Base.encode64(:binary.copy(<<1>>, 32))
  @other_kek Base.encode64(:binary.copy(<<2>>, 32))
  @secret Base.encode64(:binary.copy(<<3>>, 32))

  setup do
    saved = Application.get_env(:core, Pg)
    on_exit(fn -> Application.put_env(:core, Pg, saved) end)
  end

  describe "ensure_configured!/0" do
    test "форма верна — :ok, к базе не обращается" do
      put(keks: %{1 => @kek, 2 => @other_kek}, current_kek: 2, index_secret: @secret)

      assert :ok = Pg.ensure_configured!()
    end

    test "конфигурации нет" do
      Application.delete_env(:core, Pg)

      assert_raise ArgumentError, ~r/не задан/, &Pg.ensure_configured!/0
    end

    test "current_kek вне набора" do
      put(keks: %{1 => @kek}, current_kek: 2, index_secret: @secret)

      assert_raise ArgumentError, ~r/current_kek: 2 нет в keks:/, &Pg.ensure_configured!/0
    end

    test "KEK не 32 байта" do
      put(keks: %{1 => Base.encode64("короткий")}, current_kek: 1, index_secret: @secret)

      assert_raise ArgumentError, ~r/keks: версия 1 — base64 32 байт/, &Pg.ensure_configured!/0
    end

    test "версия — не положительное целое" do
      put(keks: %{0 => @kek}, current_kek: 0, index_secret: @secret)

      assert_raise ArgumentError, ~r/версия — положительное целое/, &Pg.ensure_configured!/0
    end

    test "версия шире 32 бит со знаком" do
      put(keks: %{2_147_483_648 => @kek}, current_kek: 2_147_483_648, index_secret: @secret)

      assert_raise ArgumentError, ~r/версия — положительное целое/, &Pg.ensure_configured!/0
    end

    test "версии повторяются" do
      put(keks: [{1, @kek}, {1, @other_kek}], current_kek: 1, index_secret: @secret)

      assert_raise ArgumentError, ~r/версии повторяются/, &Pg.ensure_configured!/0
    end

    test "нет секрета индекса" do
      put(keks: %{1 => @kek}, current_kek: 1)

      assert_raise ArgumentError, ~r/index_secret: — base64 32 байт/, &Pg.ensure_configured!/0
    end
  end

  test "без конфигурации первая операция поднимает ArgumentError" do
    Application.delete_env(:core, Pg)

    assert_raise ArgumentError, ~r/не задан/, fn -> Pg.index([{"scope", ["key"]}]) end
  end

  test "исключение реализации — вызов фасада с result: :error" do
    test = self()
    id = {__MODULE__, make_ref()}
    event = Core.Telemetry.event([:es, :personal, :call])

    :telemetry.attach(id, event, fn _event, _measurements, metadata, _config -> send(test, {:call, metadata}) end, nil)
    on_exit(fn -> :telemetry.detach(id) end)
    Application.delete_env(:core, Pg)

    assert_raise ArgumentError, fn -> Core.Es.Personal.index([{"scope", ["key"]}]) end
    assert_receive {:call, %{op: :index, result: :error}}
  end

  # ---

  defp put(env), do: Application.put_env(:core, Pg, env)
end
