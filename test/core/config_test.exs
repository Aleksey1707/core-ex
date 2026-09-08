defmodule Core.ConfigTest do
  # Тесты правят app env целиком: их нельзя гонять параллельно с чем-либо,
  # что читает тот же конфиг.
  use ExUnit.Case, async: false

  alias Core.Config

  defmodule Behaviour do
    @moduledoc false
  end

  defmodule Behaviour.Pg do
    @moduledoc false
  end

  defmodule Custom do
    @moduledoc false
  end

  defmodule Orphan do
    @moduledoc false
  end

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

  describe "repo!/1" do
    test "без ключа — реализация по конвенции `<Behaviour>.Pg`" do
      Application.delete_env(:core, Behaviour)

      assert compile_repo!(ByConvention, Behaviour) == Behaviour.Pg
    end

    test "ключ в app-env потребителя переопределяет конвенцию" do
      Application.put_env(:core, Behaviour, Custom)

      assert compile_repo!(ByConfig, Behaviour) == Custom
    end

    test "несуществующая реализация по конвенции — CompileError" do
      Application.delete_env(:core, Orphan)

      assert_raise CompileError, ~r/реализация #{inspect(Orphan.Pg)} недоступна/, fn ->
        compile_repo!(NoConventionImpl, Orphan)
      end
    end

    test "несуществующая реализация из конфига — CompileError" do
      Application.put_env(:core, Behaviour, Core.NoSuchRepo)

      assert_raise CompileError, ~r/реализация Core\.NoSuchRepo недоступна/, fn ->
        compile_repo!(NoConfiguredImpl, Behaviour)
      end
    end
  end

  describe "outbox_repo/0" do
    test "без ключа — Core.Outbox.Repo.Pg" do
      Application.delete_env(:core, Core.Outbox.Repo)

      assert Config.outbox_repo() == Core.Outbox.Repo.Pg
    end

    test "ключ переопределяет дефолт" do
      Application.put_env(:core, Core.Outbox.Repo, Custom)

      assert Config.outbox_repo() == Custom
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

    test "ловит подмену репозитория outbox модулем без колбэков" do
      Application.put_env(:core, Core.Outbox.Repo, Core.Version)

      assert_raise ArgumentError, ~r/Core\.Outbox\.Repo,` — Core\.Version не экспортирует/, fn ->
        Config.validate!()
      end
    end
  end

  defp compile_repo!(name, behaviour) do
    module = Module.concat(__MODULE__, name)

    Code.eval_string("""
    defmodule #{inspect(module)} do
      @moduledoc false

      require Core.Config

      @repo Core.Config.repo!(#{inspect(behaviour)})

      def repo, do: @repo
    end
    """)

    module.repo()
  end
end
