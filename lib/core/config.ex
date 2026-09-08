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
    «behaviour → реализация». Читается на компиляции call site (`repo!/1`), поэтому
    задаётся в `config.exs`, а не в `runtime.exs`.
  - `dao` — `Ecto.Repo` приложения.
  - `codec` — entity-фасад Codec для внутреннего wire (БД / outbox); Core ходит только
    через него (`dump/1`, `load/2`, `load!/2`).

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
  config :core, Core.Outbox, enabled: true, poll_interval_ms: 1_000, ...
  config :core, Core.Security.Secret, secret_key: "<base64 fernet key>"
  ```

  ## DI репозиториев

  Реализация резолвится по конвенции `<Behaviour>.Pg` (`repo!/1`, `outbox_repo/0`);
  ключ в конфигурации нужен только тому, кто подменяет реализацию. Решение и его
  цена — `docs/adr/0006-repo-impl-resolved-by-convention.md`.
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

  @doc """
  Реализация репозитория для доменного behaviour: из app-env потребителя, иначе `<Behaviour>.Pg`.

      @repo Config.repo!(MyApp.Domain.Users.Common.User.Repo)

  Разворачивается в `Application.compile_env/3` по ключу `behaviour` в приложении `otp_app/0`:
  значение запекается на компиляции call site, а правка ключа заставляет его перекомпилировать.
  Ключ нужен только нестандартной реализации:

      config :my_app, MyApp.Domain.Users.Common.User.Repo, MyApp.Domain....User.Repo.Memory

  Модуль-реализация проверяется на компиляции — и выведенный по конвенции, и заданный ключом.
  """
  @spec repo!(Macro.t()) :: Macro.t()

  defmacro repo!(behaviour) do
    app = otp_app()
    module = Macro.expand_literals(behaviour, __CALLER__)

    quote do
      Core.Config.ensure_repo!(
        Application.compile_env(unquote(app), unquote(module), unquote(default_repo(module))),
        unquote(module),
        unquote(app)
      )
    end
  end

  @doc false
  @spec ensure_repo!(module(), module(), atom()) :: module()

  def ensure_repo!(impl, behaviour, app) do
    case Code.ensure_compiled(impl) do
      {:module, module} ->
        module

      {:error, reason} ->
        raise CompileError,
          description:
            "Core.Config.repo!(#{inspect(behaviour)}): реализация #{inspect(impl)} недоступна " <>
              "(#{inspect(reason)}); задайте `config #{inspect(app)}, #{inspect(behaviour)}, <Impl>`"
    end
  end

  @doc """
  Реализация репозитория outbox: по той же конвенции, что и `repo!/1`, — `Core.Outbox.Repo.Pg`.

  Резолвится в рантайме, а не на компиляции: ключ читают и PromEx-плагин, и mix-задача,
  и макрос `Repo.Pg.Es` — запекание развело бы их по разным моментам чтения. Имя реализации
  при этом не упоминается статически: `Core.Outbox.Repo.Pg` ходит в `Core.Config` за `dao/0`,
  и ссылка отсюда замкнула бы цикл компиляции.
  """
  @spec outbox_repo() :: module()

  def outbox_repo, do: Application.get_env(@app, Core.Outbox.Repo, default_repo(Core.Outbox.Repo))

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

    ensure_exports!(dao(), "config :core, dao:", transact: 1, in_transaction?: 0)
    ensure_exports!(codec(), "config :core, codec:", dump: 1, load: 2, load!: 2)

    ensure_exports!(
      outbox_repo(),
      "config :core, Core.Outbox.Repo,",
      Core.Outbox.Repo.behaviour_info(:callbacks)
    )

    ensure_tz!(tz())

    :ok
  end

  # ---

  # Имя реализации вычисляется на компиляции из имени behaviour: `safe_concat` непригоден —
  # реализация компилируется позже call site, и атома её имени ещё может не быть.
  # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
  defp default_repo(behaviour), do: Module.concat(behaviour, Pg)

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

  defp ensure_exports!(module, where, funs) do
    Code.ensure_loaded?(module) ||
      raise ArgumentError, "Core.Config: `#{where}` — модуль #{inspect(module)} не найден"

    Enum.each(funs, fn {fun, arity} ->
      function_exported?(module, fun, arity) ||
        raise ArgumentError,
              "Core.Config: `#{where}` — #{inspect(module)} " <>
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
