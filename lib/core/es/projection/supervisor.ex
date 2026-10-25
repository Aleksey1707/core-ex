defmodule Core.Es.Projection.Supervisor do
  @tree_opts_schema [
    projections: [
      type: {:list, {:custom, Core.Es.Projection.Supervisor, :projection, []}},
      type_doc: "список `t:module/0`",
      required: true,
      doc: "Модули `use Core.Es.Projection` без повторов `name:`."
    ],
    enabled: [type: :boolean, required: true, doc: "`false` — дерево не стартует."],
    batch_size: [type: :pos_integer, default: 100, doc: "Событий в пачке."],
    idle_min_ms: [
      type: :pos_integer,
      default: 50,
      doc: "Первая задержка после холостой или заблокированной пачки, мс."
    ],
    poll_interval_ms: [
      type: :pos_integer,
      default: 1_000,
      doc: "Предел удвоения `idle_min_ms` и интервал при `:outdated`, мс."
    ],
    retry_min_ms: [type: :pos_integer, default: 1_000, doc: "Первая задержка повтора после отказа пачки, мс."],
    retry_max_ms: [type: :pos_integer, default: 30_000, doc: "Предел её удвоения, мс."],
    shutdown: [
      type: :pos_integer,
      default: 30_000,
      doc: "Сколько супервизор ждёт конца пачки при остановке читателя, мс."
    ],
    await: [
      type: {:in, ~w(poll inline)a},
      default: :poll,
      doc:
        "Как ждёт `await/3` модуля проекции: `:poll` — сигнал и шаги чекпоинта, `:inline` — прогон " <>
          "проекции в вызывающем процессе, только при `enabled: false` (тестовое дерево)."
    ],
    await_min_ms: [type: :pos_integer, default: 10, doc: "Первый шаг опроса чекпоинта при `await: :poll`, мс."],
    await_max_ms: [type: :pos_integer, default: 100, doc: "Предел его удвоения, мс."],
    notifications: [
      type: {:or, [:boolean, :keyword_list]},
      type_doc: "`t:boolean/0` или `t:keyword/0`",
      default: true,
      doc:
        "Сигнал чекпоинта между нодами: `true` — слушатели на соединении из `repo.config()`, keyword — " <>
          "опции соединения Postgrex поверх `repo.config()`, `false` — ни слушателей, ни `NOTIFY` пачек " <>
          "ноды. В опции читателей не передаётся: пачка берёт его из отметки."
    ]
  ]

  @moduledoc """
  Дерево проекций приложения: на каждой ноде читатели (`Core.Es.Projection.Reader`) сами
  обрабатывают новые события.

      children = [
        MyApp.Infra.DAO,
        {Core.Es.Projection.Supervisor,
         projections: [MyApp.Domain.<BC>.AccountList.Projection],
         enabled: true}
      ]

  Внутри — `rest_for_one`: `Core.Es.Projection.Registry` → `one_for_one` читателей, по одному на
  проекцию под именем её модуля, → `one_for_one` слушателей канала сигнала чекпоинта
  (`Core.Es.Projection.Listener`), по одному на каждый различный `repo:` проекций. Падение
  слушателя читателей не трогает, падение Registry перезапускает всех. Пачки одной проекции на
  разных нодах разводит блокировка пачки (`Core.Es.Projection`, «Пачка»), поэтому дерево стоит на
  всех нодах. Цикл читателя, backoff и telemetry — `Core.Es.Projection.Reader`.

  ## Опции

  Опции дерева — раздел «Опции» у `start_link/1`, те же опции принимает `watch_list/1`. Опции
  общие на все проекции; config и env библиотека не читает.

  ## Старт

  `start_link/1` проверяет опции при любом `enabled:`: отсутствующая или недопустимая опция,
  `await: :inline` при `enabled: true`, модуль без `use Core.Es.Projection`, дубль `name:` —
  `ArgumentError`. Затем:

  - `enabled: false` — `:ignore`, `info` «отключён»;
  - `projections: []` — `:ignore`, `info` «пропущен: нет проекций»;
  - иначе дерево стартует, `info` «запущен»; второй супервизор на ноде не стартует — имя Registry
    занято.

  Старт — `:ignore` или запущенное дерево — ставит отметку в `:persistent_term`: список проекций и
  опции. По ней `await/3` модуля проекции проверяет проекцию и выбирает режим ожидания.

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
  use Core.Options

  alias Core.Es.Projection
  alias Core.Es.Projection.Listener
  alias Core.Es.Projection.Reader
  alias Core.Es.Projection.Supervisor.Mark
  alias Core.Result

  require Logger

  @start_label "#{inspect(__MODULE__)}.start_link/1"
  @watch_label "#{inspect(__MODULE__)}.watch_list/1"
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

  # ===== дерево =====

  @doc "Запустить дерево проекций; `:ignore` — дерево отключено или проекций нет."
  @opts_schema @tree_opts_schema
  @spec start_link(keyword()) :: Supervisor.on_start()

  def start_link(opts) when is_list(opts), do: start(options!(opts, @start_label))

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

  `opts` — опции дерева, как у `start_link/1`. При `enabled: false` элементов нет: читателей на
  ноде нет, и `up=0` был бы ложной тревогой.
  """
  @opts_schema @tree_opts_schema
  @spec watch_list(keyword()) :: [watch_item()]

  def watch_list(opts) when is_list(opts) do
    case options!(opts, @watch_label) do
      %{enabled: false} -> []
      %{projections: projections} -> Enum.map(projections, &watch_item/1)
    end
  end

  # ---

  defp options!(opts, label) do
    ensure_await!(Keyword.fetch!(opts, :enabled), Keyword.fetch!(opts, :await), label)
    ensure_unique_names!(Enum.map(Keyword.fetch!(opts, :projections), &{&1, &1.__es_projection__()}), label)

    Map.new(opts)
  end

  defp ensure_await!(true, :inline, label) do
    raise ArgumentError,
          "#{label}: await: :inline — только при enabled: false: пачки читателей и прогона " <>
            "в вызывающем процессе шли бы вперемешку"
  end

  defp ensure_await!(_enabled, _await, _label), do: :ok

  defp ensure_unique_names!(declarations, label) do
    repeated =
      declarations
      |> Enum.group_by(fn {_mod, declaration} -> declaration.name end, &elem(&1, 0))
      |> Enum.filter(fn {_name, mods} -> length(mods) > 1 end)

    case repeated do
      [] ->
        :ok

      [{name, mods} | _] ->
        raise ArgumentError,
              "#{label}: name: #{inspect(name)} у нескольких проекций: #{inspect(mods)}"
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

  # ===== проверка опций =====

  @doc false
  @spec projection(term()) :: Result.t(module(), String.t())

  def projection(value) do
    if is_atom(value) and Core.Helper.Module.exports?(value, :__es_projection__, 0),
      do: {:ok, value},
      else: {:error, "ожидается модуль use Core.Es.Projection, получено #{inspect(value)}"}
  end
end
