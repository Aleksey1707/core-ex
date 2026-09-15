defmodule Core.Es.Projection.Supervisor do
  @moduledoc """
  Дерево проекций приложения: на каждой ноде читатели (`Core.Es.Projection.Reader`) сами
  обрабатывают новые события.

      children = [
        MyApp.DAO,
        {Core.Es.Projection.Supervisor,
         projections: [MyApp.Domain.<BC>.<Actor>.AccountList.Projection],
         enabled: true}
      ]

  Внутри — `rest_for_one`: `Core.Es.Projection.Registry` → `one_for_one` читателей, по одному на
  проекцию под именем её модуля, → `one_for_one` слушателей канала сигнала чекпоинта
  (`Core.Es.Projection.Listener`), по одному на каждый различный `repo:` проекций. Падение
  слушателя читателей не трогает, падение Registry перезапускает всех. Пачки одной проекции на
  разных нодах разводит блокировка пачки (`Core.Es.Projection`, «Пачка»), поэтому дерево стоит на
  всех нодах. Цикл читателя, backoff и telemetry — `Core.Es.Projection.Reader`.

  ## Opts

  - `projections:` — обязательна; модули `use Core.Es.Projection` без повторов `name:`
  - `enabled:` — обязательна; `false` — дерево не стартует
  - `batch_size:` — событий в пачке, по умолчанию 100
  - `idle_min_ms:` — первая задержка после холостой или заблокированной пачки, по умолчанию 50
  - `poll_interval_ms:` — предел её удвоения и интервал при `:outdated`, по умолчанию 1 000
  - `retry_min_ms:` — первая задержка повтора после отказа пачки, по умолчанию 1 000
  - `retry_max_ms:` — предел её удвоения, по умолчанию 30 000
  - `shutdown:` — сколько супервизор ждёт конца пачки при остановке читателя, по умолчанию 30 000
  - `await:` — как ждёт `Core.Es.Projection.await/4`: `:poll` (по умолчанию) — сигнал и шаги чекпоинта,
    `:inline` — прогон проекции в вызывающем процессе, только при `enabled: false` (тестовое дерево)
  - `await_min_ms:` — первый шаг опроса чекпоинта при `await: :poll`, по умолчанию 10
  - `await_max_ms:` — предел его удвоения, по умолчанию 100
  - `notifications:` — сигнал чекпоинта между нодами: `true` (по умолчанию) — слушатели на
    соединении из `repo.config()`, keyword — опции соединения Postgrex поверх `repo.config()`,
    `false` — ни слушателей, ни `NOTIFY` пачек ноды

  Числа — положительные целые, в миллисекундах. Опции общие на все проекции; config и env
  библиотека не читает. `notifications:` в опции читателей не передаётся: пачка берёт его из
  отметки.

  ## Старт

  `start_link/1` проверяет опции при любом `enabled:`: отсутствующая или недопустимая опция,
  `await: :inline` при `enabled: true`, модуль без `use Core.Es.Projection`, дубль `name:` —
  `ArgumentError`. Затем:

  - `enabled: false` — `:ignore`, `info` «отключён»;
  - `projections: []` — `:ignore`, `info` «пропущен: нет проекций»;
  - иначе дерево стартует, `info` «запущен»; второй супервизор на ноде не стартует — имя Registry
    занято.

  Старт — `:ignore` или запущенное дерево — ставит отметку в `:persistent_term`: список проекций и
  опции. По ней `Core.Es.Projection.await/4` проверяет проекцию и выбирает режим ожидания.

  `Core.Es.Store.append/5` после commit будит читателей типа агрегата пачки через Registry. Нода с
  `enabled: false` не будит: события её записи читатели других нод находят опросом.

  ## Сигнал чекпоинта между нодами

  Пачка шлёт `NOTIFY` в своей транзакции, слушатель каждой ноды переводит уведомление в сигнал
  чекпоинта для ожидающих на ней (протокол — `Core.Es.Projection.Listener`). Слушатель держит своё
  соединение: нода открывает по соединению на каждый различный `repo:` проекций, и их учитывают
  лимиты соединений базы и пулера. `LISTEN` через pgbouncer в transaction mode уведомлений не
  получает — keyword с прямым хостом ведёт слушателя в обход пулера. Приложению на одной ноде
  хватает сигнала внутри VM: `notifications: false` снимает и соединение, и блокировку коммита,
  которую `NOTIFY` берёт и без слушателей (`docs/adr/0013-checkpoint-signal-listen-notify.md`).
  Нода с `enabled: false` соединений не открывает.
  """

  use Supervisor

  alias Core.Es.Projection
  alias Core.Es.Projection.Listener
  alias Core.Es.Projection.Reader
  alias Core.Es.Projection.Supervisor.Mark
  alias Core.Helper.StartOpts

  require Logger

  @label "Es.Projection.Supervisor"
  @defaults [
    batch_size: 100,
    idle_min_ms: 50,
    poll_interval_ms: 1_000,
    retry_min_ms: 1_000,
    retry_max_ms: 30_000,
    shutdown: 30_000,
    await_min_ms: 10,
    await_max_ms: 100
  ]
  @reader_keys ~w(batch_size idle_min_ms poll_interval_ms retry_min_ms retry_max_ms shutdown)a

  @typedoc "Проверенные опции дерева — они же отметка старта."
  @type options :: %{
          projections: [module()],
          enabled: boolean(),
          batch_size: pos_integer(),
          idle_min_ms: pos_integer(),
          poll_interval_ms: pos_integer(),
          retry_min_ms: pos_integer(),
          retry_max_ms: pos_integer(),
          shutdown: pos_integer(),
          await: :poll | :inline,
          await_min_ms: pos_integer(),
          await_max_ms: pos_integer(),
          notifications: boolean() | keyword()
        }

  @typedoc "Элемент `watch:` плагина `Core.Workers.PromEx`."
  @type watch_item :: %{component: String.t(), name: module()}

  @doc "Запустить дерево проекций; `:ignore` — дерево отключено или проекций нет."
  @spec start_link(keyword()) :: Supervisor.on_start()

  def start_link(opts) when is_list(opts), do: start(options!(opts))

  @doc false
  @spec init(options()) :: {:ok, {Supervisor.sup_flags(), [Supervisor.child_spec()]}}

  @impl true
  def init(%{projections: projections} = options) do
    reader_opts = Map.to_list(Map.take(options, @reader_keys))
    readers = Enum.map(projections, &{Reader, [projection: &1] ++ reader_opts})

    children = [
      Projection.Registry,
      %{
        id: :readers,
        start: {Supervisor, :start_link, [readers, [strategy: :one_for_one]]},
        type: :supervisor
      }
      | listeners(projections, options.notifications)
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc """
  Элементы `watch:` плагина `Core.Workers.PromEx` — по читателю на проекцию под именем её модуля,
  `component: "es_projection:<name>"`.

  `opts` — опции дерева, проверяются как в `start_link/1`. При `enabled: false` элементов нет:
  читателей на ноде нет, и `up=0` был бы ложной тревогой.
  """
  @spec watch_list(keyword()) :: [watch_item()]

  def watch_list(opts) when is_list(opts) do
    case options!(opts) do
      %{enabled: false} -> []
      %{projections: projections} -> Enum.map(projections, &watch_item/1)
    end
  end

  # ---

  defp options!(opts) do
    projections = StartOpts.list!(@label, opts, :projections)
    enabled = StartOpts.boolean!(@label, opts, :enabled)
    await = StartOpts.one_of!(@label, opts, :await, ~w(poll inline)a, :poll)
    ensure_await!(enabled, await)
    notifications = notifications!(Keyword.get(opts, :notifications, true))
    ensure_unique_names!(Enum.map(projections, &declaration!/1))

    @defaults
    |> Map.new(fn {key, default} -> {key, StartOpts.pos_integer!(@label, opts, key, default)} end)
    |> Map.merge(%{
      projections: projections,
      enabled: enabled,
      await: await,
      notifications: notifications
    })
  end

  defp notifications!(value) do
    if is_boolean(value) or Keyword.keyword?(value),
      do: value,
      else: StartOpts.raise_invalid!(@label, :notifications, "true, false или keyword", value)
  end

  defp ensure_await!(true, :inline) do
    raise ArgumentError,
          "#{@label}: await: :inline — только при enabled: false: пачки читателей и прогона " <>
            "в вызывающем процессе шли бы вперемешку"
  end

  defp ensure_await!(_enabled, _await), do: :ok

  defp declaration!(mod) do
    if projection?(mod),
      do: {mod, mod.__es_projection__()},
      else: StartOpts.raise_invalid!(@label, :projections, "модуль use Core.Es.Projection", mod)
  end

  defp projection?(mod) when is_atom(mod),
    do: Code.ensure_loaded?(mod) and function_exported?(mod, :__es_projection__, 0)

  defp projection?(_other), do: false

  defp ensure_unique_names!(declarations) do
    repeated =
      declarations
      |> Enum.group_by(fn {_mod, declaration} -> declaration.name end, &elem(&1, 0))
      |> Enum.filter(fn {_name, mods} -> length(mods) > 1 end)

    case repeated do
      [] ->
        :ok

      [{name, mods} | _] ->
        raise ArgumentError,
              "#{@label}: name: #{inspect(name)} у нескольких проекций: #{inspect(mods)}"
    end
  end

  defp start(%{enabled: false} = options) do
    :ok = Mark.put(options)
    Logger.info("супервизор проекций: отключён: projections=#{names(options.projections)}")
    :ignore
  end

  defp start(%{projections: []} = options) do
    :ok = Mark.put(options)
    Logger.info("супервизор проекций: пропущен: нет проекций")
    :ignore
  end

  defp start(options) do
    with {:ok, _pid} = started <- Supervisor.start_link(__MODULE__, options) do
      :ok = Mark.put(options)
      Logger.info("супервизор проекций: запущен: projections=#{names(options.projections)}")
      started
    end
  end

  defp listeners(_projections, false), do: []

  defp listeners(projections, true), do: listeners(projections, [])

  defp listeners(projections, connection) do
    listeners =
      projections
      |> Enum.map(& &1.__es_projection__().dao)
      |> Enum.uniq()
      |> Enum.map(&{Listener, repo: &1, connection: connection})

    [
      %{
        id: :listeners,
        start: {Supervisor, :start_link, [listeners, [strategy: :one_for_one]]},
        type: :supervisor
      }
    ]
  end

  defp names(projections), do: Enum.map_join(projections, ",", &name/1)

  defp watch_item(projection),
    do: %{component: "es_projection:#{name(projection)}", name: projection}

  defp name(projection), do: projection.__es_projection__().name
end
