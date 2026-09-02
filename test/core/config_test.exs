defmodule Core.ConfigTest do
  # Тесты правят app env целиком: их нельзя гонять параллельно с чем-либо,
  # что читает тот же конфиг.
  use ExUnit.Case, async: false

  alias Core.Config

  setup do
    saved = Application.get_all_env(:core)

    on_exit(fn ->
      Enum.each(Application.get_all_env(:core), fn {key, _} ->
        Application.delete_env(:core, key)
      end)

      Enum.each(saved, fn {key, value} -> Application.put_env(:core, key, value) end)
    end)

    :ok
  end

  describe "обязательные ключи" do
    test "читаются из `config :core`" do
      assert Config.otp_app() == :core
      assert Config.dao() == Core.TestRepo
      assert Config.codec() == Core.CodecFixture.Internal
    end

    for key <- ~w(otp_app dao codec)a do
      test "#{key}/0 без конфига падает с указанием ключа" do
        Application.delete_env(:core, unquote(key))

        assert_raise ArgumentError, ~r/`config :core, #{unquote(key)}: \.\.\.`/, fn ->
          apply(Config, unquote(key), [])
        end
      end
    end
  end

  describe "tz/0" do
    test "берётся из конфига" do
      assert Config.tz() == "Asia/Vladivostok"
    end

    test "без конфига — Etc/UTC" do
      Application.delete_env(:core, :tz)

      assert Config.tz() == "Etc/UTC"
    end
  end

  describe "telemetry_prefix/0" do
    test "по умолчанию — [otp_app]" do
      Application.delete_env(:core, :telemetry_prefix)

      assert Config.telemetry_prefix() == [:core]
    end

    test "явное значение переопределяет otp_app" do
      Application.put_env(:core, :telemetry_prefix, [:my_app, :core])

      assert Config.telemetry_prefix() == [:my_app, :core]
      assert Core.Telemetry.event([:outbox]) == [:my_app, :core, :outbox]
    end
  end

  describe "validate!/0" do
    test "на рабочем конфиге проходит" do
      assert :ok = Config.validate!()
    end

    test "ловит несуществующий модуль" do
      Application.put_env(:core, :dao, Core.NoSuchRepo)

      assert_raise ArgumentError, ~r/dao:` — модуль Core\.NoSuchRepo не найден/, fn ->
        Config.validate!()
      end
    end

    test "ловит модуль без нужных функций" do
      Application.put_env(:core, :codec, Core.Version)

      assert_raise ArgumentError, ~r/codec:` — Core\.Version не экспортирует/, fn ->
        Config.validate!()
      end
    end

    test "ловит неизвестный часовой пояс" do
      Application.put_env(:core, :tz, "Mars/Olympus")

      assert_raise ArgumentError, ~r/tz: "Mars\/Olympus"/, fn ->
        Config.validate!()
      end
    end
  end
end
