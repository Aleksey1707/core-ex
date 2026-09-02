defmodule Core.Config do
  @moduledoc """
  Контракт настроек, от которых зависит Core.

  Единственная точка, где библиотека знает что-либо о приложении-потребителе.
  Всё лежит под собственным OTP-приложением `:core` — имя хоста нигде не зашито.

  ## Обязательные

  ```elixir
  config :core,
    otp_app: :my_app,
    dao: MyApp.DAO,
    codec: MyApp.Codec.Internal
  ```

  - `otp_app` — приложение, в app-env которого потребитель держит свои DI-ключи
    «behaviour → реализация». Нужно только `use Core.Repo.Pg.Es` (резолв `event_repo:`).
  - `dao` — `Ecto.Repo` приложения.
  - `codec` — entity-фасад Codec для внутреннего wire (БД / outbox); Prim-профиль
    доступен как `codec().prim()`, но Core ходит только через фасад.

  ## Опциональные

  ```elixir
  config :core,
    tz: "Etc/UTC",
    telemetry_prefix: [:my_app]
  ```

  - `tz` — часовой пояс приложения по умолчанию; дефолт `"Etc/UTC"`.
  - `telemetry_prefix` — префикс имён telemetry-событий Core; дефолт `[otp_app()]`.
    Задавайте явно, если имена метрик должны пережить смену `otp_app`.

  ## Подсистемы

  ```elixir
  config :core, Core.Outbox.Repo, Core.Outbox.Repo.Pg
  config :core, Core.Outbox, enabled: true, poll_interval_ms: 1_000, ...
  config :core, Core.Security.Secret, secret_key: "<base64 fernet key>"
  ```
  """

  @app :core
  @default_tz "Etc/UTC"

  @doc "OTP-приложение потребителя: где лежат его DI-ключи «behaviour → реализация»."
  @spec otp_app() :: atom()

  def otp_app, do: fetch!(:otp_app)

  @doc "Ecto-репозиторий приложения."
  @spec dao() :: module()

  def dao, do: fetch!(:dao)

  @doc "Entity-фасад Codec для внутреннего wire (БД / outbox)."
  @spec codec() :: module()

  def codec, do: fetch!(:codec)

  @doc "Часовой пояс приложения по умолчанию."
  @spec tz() :: String.t()

  def tz, do: Application.get_env(@app, :tz, @default_tz)

  @doc "Префикс имён telemetry-событий Core."
  @spec telemetry_prefix() :: [atom()]

  def telemetry_prefix do
    case Application.fetch_env(@app, :telemetry_prefix) do
      {:ok, prefix} when is_list(prefix) -> prefix
      _ -> [otp_app()]
    end
  end

  @doc """
  Проверить конфигурацию целиком, до первого обращения к ней из рабочего кода.

  Звать из `start/2` приложения-потребителя: обязательные ключи заданы, `dao`
  и `codec` загружаются и экспортируют нужные функции, `tz` известен системе.
  """
  @spec validate!() :: :ok

  def validate! do
    _ = otp_app()

    ensure_exports!(dao(), :dao, transact: 1, in_transaction?: 0)
    ensure_exports!(codec(), :codec, dump: 1, load: 2, prim: 0)
    ensure_tz!(tz())

    :ok
  end

  # ---

  defp fetch!(key) do
    case Application.fetch_env(@app, key) do
      {:ok, value} ->
        value

      :error ->
        raise ArgumentError,
              "Core.Config: не задан `config :core, #{key}: ...` " <>
                "(контракт настроек — в docs `Core.Config` и README)"
    end
  end

  defp ensure_exports!(module, key, funs) do
    Code.ensure_loaded?(module) ||
      raise ArgumentError,
            "Core.Config: `config :core, #{key}:` — модуль #{inspect(module)} не найден"

    Enum.each(funs, fn {fun, arity} ->
      function_exported?(module, fun, arity) ||
        raise ArgumentError,
              "Core.Config: `config :core, #{key}:` — #{inspect(module)} " <>
                "не экспортирует #{fun}/#{arity}"
    end)
  end

  defp ensure_tz!(tz) do
    case DateTime.shift_zone(DateTime.utc_now(), tz) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        raise ArgumentError,
              "Core.Config: `config :core, tz: #{inspect(tz)}` — #{inspect(reason)}"
    end
  end
end
