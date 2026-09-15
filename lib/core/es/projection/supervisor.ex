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
  проекцию под именем её модуля. Пачки одной проекции на разных нодах разводит блокировка пачки
  (`Core.Es.Projection`, «Пачка»), поэтому дерево стоит на всех нодах. Цикл читателя, backoff и
  telemetry — `Core.Es.Projection.Reader`.

  ## Opts

  - `projections:` — обязательна; модули `use Core.Es.Projection` без повторов `name:`
  - `enabled:` — обязательна; `false` — дерево не стартует
  - `batch_size:` — событий в пачке, по умолчанию 100
  - `idle_min_ms:` — первая задержка после холостой или заблокированной пачки, по умолчанию 50
  - `poll_interval_ms:` — предел её удвоения и интервал при `:outdated`, по умолчанию 1 000
  - `retry_min_ms:` — первая задержка повтора после отказа пачки, по умолчанию 1 000
  - `retry_max_ms:` — предел её удвоения, по умолчанию 30 000
  - `shutdown:` — сколько супервизор ждёт конца пачки при остановке читателя, по умолчанию 30 000
  - `await:` — как ждёт `Core.Es.Projection.await/4`: `:poll` (по умолчанию) — опрос чекпоинта,
    `:inline` — прогон проекции в вызывающем процессе, только при `enabled: false` (тестовое дерево)

  Числа — положительные целые, в миллисекундах. Опции общие на все проекции; config и env
  библиотека не читает.

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
  """

  use Supervisor

  alias Core.Es.Projection
  alias Core.Es.Projection.Reader
  alias Core.Helper.StartOpts

  require Logger

  @label "Es.Projection.Supervisor"
  @mark_key {__MODULE__, :mark}
  @defaults [
    batch_size: 100,
    idle_min_ms: 50,
    poll_interval_ms: 1_000,
    retry_min_ms: 1_000,
    retry_max_ms: 30_000,
    shutdown: 30_000
  ]

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
          await: :poll | :inline
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
    reader_opts = Map.to_list(Map.drop(options, ~w(projections enabled await)a))
    readers = Enum.map(projections, &{Reader, [projection: &1] ++ reader_opts})

    children = [
      Projection.Registry,
      %{
        id: :readers,
        start: {Supervisor, :start_link, [readers, [strategy: :one_for_one]]},
        type: :supervisor
      }
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

  @doc false
  @spec mark() :: options() | nil

  def mark, do: :persistent_term.get(@mark_key, nil)

  # ---

  defp options!(opts) do
    projections = StartOpts.list!(@label, opts, :projections)
    enabled = StartOpts.boolean!(@label, opts, :enabled)
    await = StartOpts.one_of!(@label, opts, :await, ~w(poll inline)a, :poll)
    ensure_await!(enabled, await)
    ensure_unique_names!(Enum.map(projections, &declaration!/1))

    @defaults
    |> Map.new(fn {key, default} -> {key, StartOpts.pos_integer!(@label, opts, key, default)} end)
    |> Map.merge(%{projections: projections, enabled: enabled, await: await})
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
    put_mark(options)
    Logger.info("супервизор проекций: отключён: projections=#{names(options.projections)}")
    :ignore
  end

  defp start(%{projections: []} = options) do
    put_mark(options)
    Logger.info("супервизор проекций: пропущен: нет проекций")
    :ignore
  end

  defp start(options) do
    with {:ok, _pid} = started <- Supervisor.start_link(__MODULE__, options) do
      put_mark(options)
      Logger.info("супервизор проекций: запущен: projections=#{names(options.projections)}")
      started
    end
  end

  defp put_mark(options), do: :persistent_term.put(@mark_key, options)

  defp names(projections), do: Enum.map_join(projections, ",", &name/1)

  defp watch_item(projection),
    do: %{component: "es_projection:#{name(projection)}", name: projection}

  defp name(projection), do: projection.__es_projection__().name
end
