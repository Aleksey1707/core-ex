defmodule Core.PromEx.Dashboards do
  @moduledoc """
  Дашборды подсистем библиотеки: рендер шаблонов `priv/dashboards/*.json.eex` для модуля PromEx
  приложения (ADR-0089).

  Рендер идёт через `PromEx.DashboardRenderer`, как у штатных дашбордов PromEx. Параметры шаблона
  собираются по возрастанию приоритета:

  1. умолчания рендерера — префиксы штатных плагинов (`prom_ex_metric_prefix` и др.);
  2. умолчания библиотеки — префикс плагина подсистемы и пороги панелей (таблица ниже);
  3. `dashboard_assigns/0` модуля PromEx приложения.

  `otp_app`, `title` и `uid` строятся от `otp_app` из `use PromEx` приложения и имени дашборда;
  `dashboard_assigns/0` их не меняет: один ключ на все дашборды дал бы им общий заголовок и `uid`.
  `uid` — MD5 строки `"<otp_app>/<имя дашборда>"` в 32 hex-символах верхнего регистра, как форма
  `uid` штатных дашбордов PromEx. Штатный `__grafana_dashboard_uid__/3` не годится: в его хеш
  входит имя модуля PromEx, и переименованный модуль дал бы в Grafana второй дашборд рядом со
  старым. Хеш, а не читаемое `"<otp_app>-<имя>"`: длина постоянна и укладывается в лимит Grafana
  (40 символов) при любом `otp_app`, а усечение читаемой формы сводило бы длинные `otp_app` с
  общим началом к одному `uid`.
  `datasource_id` — uid datasource Prometheus в Grafana, обязателен в `dashboard_assigns/0`,
  умолчания нет.

  Префикс метрик и единица длительности по умолчанию следуют опциям плагина подсистемы в
  `plugins/0` (`metric_prefix:`, `duration_unit:`), как имена метрик самого плагина. Параметры
  префикса и длительности называются по ключу префикса плагина: `<ключ>_metric_prefix`,
  `<ключ>_duration_unit`, `<ключ>_duration_axis_unit`.

  | Дашборд | Плагин | Параметр | Умолчание |
  |---|---|---|---|
  | `outbox` | `Core.Outbox.PromEx` | `outbox_metric_prefix` | `metric_prefix:` плагина, `"<otp_app>_prom_ex_outbox"` |
  | | | `outbox_duration_unit` | `duration_unit:` плагина (мн. ч.) или `"milliseconds"` |
  | | | `outbox_duration_axis_unit` | единица оси Grafana по `duration_unit:` плагина, `"ms"` |
  | | | `outbox_queue_warning` / `outbox_queue_critical` | `100` / `500` записей |
  | | | `outbox_oldest_age_warning` / `outbox_oldest_age_critical` | `30` / `120` секунд |
  | | | `outbox_expired_locks_warning` / `outbox_expired_locks_critical` | `1` / `10` записей |
  | `mq` | `Core.Mq.PromEx` | `mq_metric_prefix` | `metric_prefix:` плагина, `"<otp_app>_prom_ex_mq"` |
  | | | `mq_duration_unit` | `duration_unit:` плагина (мн. ч.) или `"milliseconds"` |
  | | | `mq_duration_axis_unit` | единица оси Grafana по `duration_unit:` плагина, `"ms"` |
  | `kafka` | `Core.Mq.PromEx` | `mq_metric_prefix` | как у `mq` |
  | | | `kafka_backlog_critical` | `1000` непрочитанных сообщений партиции |
  | `es` | `Core.Es.PromEx` | `es_metric_prefix` | `metric_prefix:` плагина, `"<otp_app>_prom_ex_es"` |
  | | | `es_duration_unit` | `duration_unit:` плагина (мн. ч.) или `"milliseconds"` |
  | | | `es_duration_axis_unit` | единица оси Grafana по `duration_unit:` плагина, `"ms"` |
  | | | `es_projection_lag_warning` / `es_projection_lag_critical` | `30` / `60` секунд |
  | `cache` | `Core.Cache.PromEx` | `cache_metric_prefix` | `metric_prefix:` плагина, `"<otp_app>_prom_ex_cache"` |
  | | | `cache_hit_ratio_warning` / `cache_hit_ratio_critical` | `0.9` / `0.5` — ниже доли попаданий |
  | `workers` | `Core.Workers.PromEx` | `workers_metric_prefix` | `metric_prefix:` плагина, `"<otp_app>_prom_ex_workers"` |
  | | `Core.Cgroup.PromEx` | `cgroup_metric_prefix` | `metric_prefix:` плагина, `"<otp_app>_prom_ex_cgroup"` |
  | | | `workers_container_memory_warning` / `workers_container_memory_critical` | `500_000_000` / `1_000_000_000` байт |
  | | `Core.PromEx.Safe` | `workers_collect_errors_pattern` | `"<otp_app>_prom_ex_.+_collect_errors_total"` |
  | `external` | `Core.External.PromEx` | `external_metric_prefix` | `metric_prefix:` плагина, `"<otp_app>_prom_ex_external"` |
  | | | `external_duration_unit` | `duration_unit:` плагина (мн. ч.) или `"milliseconds"` |
  | | | `external_duration_axis_unit` | единица оси Grafana по `duration_unit:` плагина, `"ms"` |

  Имена проекций, агрегатов и кешей шаблоны не несут: их дают переменные дашборда `projection`,
  `type` и `cache` по меткам метрик.

  Дашборд `workers` входит в набор по `Core.Workers.PromEx`; без `Core.Cgroup.PromEx` в `plugins/0`
  панели памяти контейнера пусты. `workers_collect_errors_pattern` — регулярка PromQL по
  `__name__` счётчиков сбоев сбора `<префикс плагина>_collect_errors_total` всех плагинов
  `Core.*.PromEx`: плагин со своим `metric_prefix:` вне `<otp_app>_prom_ex_` требует своей
  регулярки. Система внешнего вызова у дашборда `external` — переменная `system`.

  Выгрузку в каталог дашбордов приложения делает `mix core.dashboards.export`; совпадение выгрузок
  с текущим рендером проверяют `stale/2` и вариант для теста `assert_fresh!/2`, форму панелей всех
  дашбордов каталога — `form_violations/3` и `assert_form!/3`.
  """

  use Core.Options

  alias PromEx.DashboardRenderer

  defmodule Stale do
    @moduledoc "Выгрузка дашборда подсистемы библиотеки разошлась с рендером (`assert_fresh!/2`)."

    defexception [:message]
  end

  defmodule FormError do
    @moduledoc """
    Форма панелей нарушена (`assert_form!/3`): `message` — читаемый перечень, `violations` —
    нарушения в форме `form_violations/3`.
    """

    defexception message: "форма панелей нарушена", violations: []
  end

  @typedoc "Имя дашборда подсистемы библиотеки; файл выгрузки — `<имя>.json`."
  @type name :: :outbox | :mq | :kafka | :es | :cache | :workers | :external

  @typedoc "Выгрузка `file` дашборда `dashboard`, разошедшаяся с рендером."
  @type stale_export :: %{file: Path.t(), dashboard: name()}

  @typedoc "Правило формы панелей; таблица — `form_violations/3`."
  @type form_rule :: :summary_legend | :state_timeline | :timeseries_legend | :state_legend | :variable_filter

  @typedoc "Нарушение формы: дашборд, заголовок панели, правило и растущие метки, на которых оно сработало."
  @type form_violation :: %{dashboard: String.t(), panel: String.t(), rule: form_rule(), labels: [String.t()]}

  @dashboards [
    outbox: %{
      plugin: Core.Outbox.PromEx,
      label: "Outbox",
      prefix: :outbox,
      duration?: true,
      thresholds: [
        outbox_queue_warning: 100,
        outbox_queue_critical: 500,
        outbox_oldest_age_warning: 30,
        outbox_oldest_age_critical: 120,
        outbox_expired_locks_warning: 1,
        outbox_expired_locks_critical: 10
      ]
    },
    mq: %{
      plugin: Core.Mq.PromEx,
      label: "MQ",
      options: ~w(stream_readers)a,
      prefix: :mq,
      duration?: true,
      thresholds: []
    },
    kafka: %{
      plugin: Core.Mq.PromEx,
      label: "Kafka",
      options: ~w(kafka_readers)a,
      prefix: :mq,
      duration?: false,
      thresholds: [kafka_backlog_critical: 1_000]
    },
    es: %{
      plugin: Core.Es.PromEx,
      label: "Event Sourcing",
      prefix: :es,
      duration?: true,
      thresholds: [es_projection_lag_warning: 30, es_projection_lag_critical: 60]
    },
    cache: %{
      plugin: Core.Cache.PromEx,
      label: "Cache",
      prefix: :cache,
      duration?: false,
      thresholds: [cache_hit_ratio_warning: 0.9, cache_hit_ratio_critical: 0.5]
    },
    workers: %{
      plugin: Core.Workers.PromEx,
      label: "Workers",
      prefix: :workers,
      duration?: false,
      thresholds: [workers_container_memory_warning: 500_000_000, workers_container_memory_critical: 1_000_000_000]
    },
    external: %{
      plugin: Core.External.PromEx,
      label: "External",
      prefix: :external,
      duration?: true,
      thresholds: []
    }
  ]
  @names Keyword.keys(@dashboards)
  @assign_keys for prefix <- [:cgroup | for({_name, %{prefix: prefix}} <- @dashboards, do: prefix)],
                   kind <- ~w(metric_prefix duration_unit duration_axis_unit)a,
                   into: %{},
                   do: {{prefix, kind}, :"#{prefix}_#{kind}"}

  # ===== набор =====

  @doc "Все дашборды подсистем библиотеки."
  @spec names() :: [name()]

  def names, do: @names

  @doc """
  Набор дашбордов по умолчанию для модуля PromEx приложения — по его `plugins/0`.

  Дашборд входит в набор, если в `plugins/0` есть плагин его подсистемы. Дашборды `Core.Mq.PromEx`
  требуют ещё и опции плагина: `mq` — `stream_readers:`, `kafka` — `kafka_readers:`; иначе в
  Grafana лёг бы дашборд транспорта, которого у приложения нет. Старый ключ `readers:` плагин не
  читает, и `mq` по нему не входит.
  """
  @spec defaults(module()) :: [name()]

  def defaults(prom_ex) when is_atom(prom_ex) do
    plugins = plugins(prom_ex)

    for {name, %{plugin: plugin} = dashboard} <- @dashboards,
        plugin_opts = Map.get(plugins, plugin),
        is_list(plugin_opts) and options_given?(dashboard, plugin_opts),
        do: name
  end

  # ---

  defp options_given?(%{options: options}, plugin_opts), do: Enum.any?(options, &Keyword.has_key?(plugin_opts, &1))
  defp options_given?(%{}, _plugin_opts), do: true

  # ===== рендер =====

  @doc """
  Отрендерить дашборд `name` для модуля PromEx приложения — JSON выгрузки.

  `ArgumentError` — в `dashboard_assigns/0` нет `datasource_id` или параметры дали невалидный JSON.
  """
  @spec render(module(), name()) :: String.t()

  def render(prom_ex, name) when is_atom(prom_ex) and name in @names do
    otp_app = prom_ex.__otp_app__()
    %{label: label} = dashboard = Keyword.fetch!(@dashboards, name)
    plugins = plugins(prom_ex)

    :core
    |> DashboardRenderer.build("dashboards/#{name}.json", otp_app)
    |> DashboardRenderer.merge_assigns(library_assigns(dashboard, otp_app, plugins))
    |> DashboardRenderer.merge_assigns(neighbour_assigns(name, otp_app, plugins))
    |> DashboardRenderer.merge_assigns(prom_ex.dashboard_assigns())
    |> DashboardRenderer.merge_assigns(identity_assigns(otp_app, name, label))
    |> check_datasource!(prom_ex)
    |> render_template()
    |> DashboardRenderer.decode_dashboard()
    |> rendered!(prom_ex, name)
  end

  # ---

  defp library_assigns(%{plugin: plugin, prefix: prefix, thresholds: thresholds} = dashboard, otp_app, plugins) do
    plugin_opts = Map.get(plugins, plugin, [])
    prefix_assigns(prefix, plugin_opts, otp_app) ++ duration_assigns(dashboard, plugin_opts) ++ thresholds
  end

  defp prefix_assigns(prefix, plugin_opts, otp_app),
    do: [{assign_key(prefix, :metric_prefix), metric_prefix(plugin_opts, otp_app, prefix)}]

  defp duration_assigns(%{duration?: false}, _plugin_opts), do: []

  defp duration_assigns(%{duration?: true, prefix: prefix}, plugin_opts) do
    [
      {assign_key(prefix, :duration_unit), duration_unit(plugin_opts)},
      {assign_key(prefix, :duration_axis_unit), duration_axis_unit(plugin_opts)}
    ]
  end

  # Параметры панелей дашборда на метриках соседних плагинов — по опциям этих плагинов в `plugins/0`.
  defp neighbour_assigns(:workers, otp_app, plugins) do
    prefix_assigns(:cgroup, Map.get(plugins, Core.Cgroup.PromEx, []), otp_app) ++
      [workers_collect_errors_pattern: "#{otp_app}_prom_ex_.+_collect_errors_total"]
  end

  defp neighbour_assigns(_name, _otp_app, _plugins), do: []

  defp assign_key(prefix, kind), do: Map.fetch!(@assign_keys, {prefix, kind})

  defp identity_assigns(otp_app, name, label) do
    [
      otp_app: otp_app,
      title: "#{Macro.camelize(Atom.to_string(otp_app))} - #{label}",
      uid: Base.encode16(:crypto.hash(:md5, "#{otp_app}/#{name}"))
    ]
  end

  defp metric_prefix(plugin_opts, otp_app, plugin) do
    plugin_opts
    |> Keyword.get(:metric_prefix, PromEx.metric_prefix(otp_app, plugin))
    |> Enum.join("_")
  end

  defp duration_unit(plugin_opts) do
    plugin_opts
    |> Keyword.get(:duration_unit, :millisecond)
    |> PromEx.Utils.make_plural_atom()
    |> Atom.to_string()
  end

  defp duration_axis_unit(plugin_opts) do
    case duration_unit(plugin_opts) do
      "seconds" -> "s"
      "milliseconds" -> "ms"
      "microseconds" -> "µs"
      "nanoseconds" -> "ns"
    end
  end

  defp check_datasource!(%DashboardRenderer{assigns: assigns} = dashboard, prom_ex) do
    case Keyword.get(assigns, :datasource_id) do
      <<_, _::binary>> ->
        dashboard

      other ->
        raise ArgumentError,
              "Core.PromEx.Dashboards.render/2: #{inspect(prom_ex)}.dashboard_assigns/0 — ожидается " <>
                "datasource_id: uid datasource Prometheus строкой, получено #{inspect(other)}"
    end
  end

  defp render_template(%DashboardRenderer{file_type: :eex, file_contents: contents, assigns: assigns} = dashboard),
    do: %{dashboard | rendered_file: EEx.eval_string(contents, assigns: assigns)}

  defp rendered!(%DashboardRenderer{valid_json?: true, rendered_file: json}, _prom_ex, _name), do: json

  defp rendered!(%DashboardRenderer{error: error}, prom_ex, name) do
    raise ArgumentError,
          "Core.PromEx.Dashboards.render/2: дашборд #{name} для #{inspect(prom_ex)} не отрендерился: " <>
            inspect(error)
  end

  # ===== свежесть выгрузок =====

  @doc """
  Выгрузки дашбордов подсистем библиотеки в каталоге `dir`, разошедшиеся с текущим рендером для
  модуля PromEx приложения; пустой список — все выгрузки свежие.

  Выгрузка узнаётся по имени файла: `<имя>.json` для каждого имени из `names/0` — так её называет
  `mix core.dashboards.export`. Другие файлы каталога — доменные и штатные дашборды — не
  проверяются; дашборд, которого в каталоге нет, нарушением не считается. Файл сравнивается с
  рендером как JSON: форматирование и перевод строки в конце не важны, ручная правка, старый
  порог, выгрузка другого `otp_app`, невалидный JSON или нечитаемый файл — расхождение.

  `ArgumentError` — каталога `dir` нет: опечатка в пути иначе молча дала бы пустой список.
  """
  @spec stale(module(), Path.t()) :: [stale_export()]

  def stale(prom_ex, dir) when is_atom(prom_ex) and is_binary(dir) do
    dir!(dir, "stale/2")

    for name <- @names,
        file = Path.join(dir, "#{name}.json"),
        File.regular?(file),
        decode_file(file) != Jason.decode(render(prom_ex, name)),
        do: %{file: file, dashboard: name}
  end

  @doc """
  Вариант `stale/2` для теста приложения: `:ok` или `Core.PromEx.Dashboards.Stale` с перечнем
  разошедшихся выгрузок и командой переэкспорта каждой.
  """
  @spec assert_fresh!(module(), Path.t()) :: :ok

  def assert_fresh!(prom_ex, dir) when is_atom(prom_ex) and is_binary(dir) do
    case stale(prom_ex, dir) do
      [] -> :ok
      exports -> raise Stale, stale_message(exports, prom_ex, dir)
    end
  end

  # ---

  defp decode_file(file) do
    with {:ok, json} <- File.read(file), do: Jason.decode(json)
  end

  defp stale_message(exports, prom_ex, dir) do
    lines =
      for %{file: file, dashboard: name} <- exports do
        "  #{file}: mix core.dashboards.export --module #{inspect(prom_ex)} --dashboard #{name} --out #{dir}"
      end

    Enum.join(
      [
        "Core.PromEx.Dashboards.assert_fresh!/2: выгрузки разошлись с рендером для #{inspect(prom_ex)} — " <>
          "выгрузить заново, руками не править:"
        | lines
      ],
      "\n"
    )
  end

  # ===== форма панелей =====

  @fixed_labels ~w(result outcome status error op operation channel kind collector reason)
  @summaries ~w(stat gauge bargauge)
  @unfiltered ["table", "state-timeline" | @summaries]
  @form_rules [
    summary_legend: "сводка без legendFormat или с растущей меткой в нём",
    state_timeline: "state-timeline с растущей меткой",
    timeseries_legend: "легенда графика — не таблица справа: lastNotNull, max, сортировка по max desc",
    state_legend: "состояние «1 = проблема»: легенда не список справа без calcs или подсказка не multi с hideZeros",
    variable_filter: ~s(нет фильтра переменной дашборда: label=~"$label", multi, All, allValue ".*")
  ]
  @form_norm "`deps/core/docs/rules/app/21-observability.md`, «Форма панелей»"
  @table_legend %{
    "displayMode" => "table",
    "placement" => "right",
    "calcs" => ~w(lastNotNull max),
    "sortBy" => "Max",
    "sortDesc" => true
  }
  @state_legend %{"displayMode" => "list", "placement" => "right", "calcs" => []}
  @state_tooltip %{"mode" => "multi", "hideZeros" => true}
  @variable %{"multi" => true, "includeAll" => true, "allValue" => ".*"}

  @opts_schema [
    fixed_labels: [
      type: {:list, :string},
      default: [],
      doc: "Фиксированные метки приложения сверх списка библиотеки."
    ]
  ]
  @doc """
  Нарушения формы панелей (#{@form_norm}) — пустой список при норме.

  `source` — каталог дашбордов (`*.json`, имя дашборда в нарушении — имя файла) либо один дашборд
  `{имя, декодированный JSON}`. Каталога нет — `ArgumentError`: проверка пустоты прошла бы
  вхолостую. Файл каталога с именем шаблона PromEx (`beam.json`, `application.json`, …) —
  выгрузка штатного дашборда, его форму задаёт PromEx, и проверка его пропускает; доменный
  дашборд с таким именем выпал бы из проверки вместе с ним, поэтому имя шаблона PromEx ему не
  дают.

  Проверяются запросы панелей (и панелей свёрнутых рядов) с метриками плагинов модуля PromEx:
  префикс `<otp_app>_prom_ex_` (умолчание `PromEx.metric_prefix/2` у каждого плагина) и
  `metric_prefix:` плагинов из `plugins/0`. Метки экспортёров (`datname`, `mountpoint`) задаёт
  окружение, их запросы вне охвата. Метки панели берутся из `legendFormat` запроса; растущая —
  любая вне закрытого списка фиксированных `#{Enum.join(@fixed_labels, ", ")}` и
  `fixed_labels:`.

  | Правило | Нарушение |
  |---|---|
  | `:summary_legend` | `stat` / `gauge` / `bargauge` без `legendFormat` или с растущей меткой в нём |
  | `:state_timeline` | `state-timeline` с растущей меткой |
  | `:timeseries_legend` | `timeseries` с растущей меткой: легенда не таблица справа (`lastNotNull`, `max`, `Max`↓) |
  | `:state_legend` | состояние `1 - …`: легенда не список справа без `calcs`, подсказка не `multi` + `hideZeros` |
  | `:variable_filter` | растущая метка без `<метка>=~"$<метка>"` и переменной `multi`, All, `allValue: ".*"` |

  `:variable_filter` не проверяется у `table` (прокручивает строки) и у сводки и `state-timeline`: растущая
  метка там уже нарушение.

  ## Опции

  #{Core.Options.docs(@opts_schema)}
  """
  @spec form_violations(module(), Path.t() | {String.t(), map()}, keyword()) :: [form_violation()]

  def form_violations(prom_ex, source, opts \\ []) when is_atom(prom_ex) and is_list(opts) do
    prefixes = metric_prefixes(prom_ex)
    fixed = @fixed_labels ++ Keyword.fetch!(opts, :fixed_labels)

    for {name, dashboard} <- form_sources(source),
        target <- form_targets(dashboard, prefixes, fixed),
        violation <- target_violations(target),
        uniq: true,
        do: Map.put(violation, :dashboard, name)
  end

  @doc """
  `form_violations/3` для теста приложения: `:ok` при норме, иначе `Core.PromEx.Dashboards.FormError`
  с перечнем нарушений — дашборд, панель, правило, растущие метки. `source` и опции
  (`fixed_labels:`) — как у `form_violations/3`.

      test "форма панелей" do
        Core.PromEx.Dashboards.assert_form!(MyAppApp.PromEx, "deploy/monitoring/grafana/dashboards")
      end
  """
  @spec assert_form!(module(), Path.t() | {String.t(), map()}, keyword()) :: :ok

  def assert_form!(prom_ex, source, opts \\ []) when is_atom(prom_ex) do
    case form_violations(prom_ex, source, opts) do
      [] -> :ok
      violations -> raise FormError, message: form_message(violations), violations: violations
    end
  end

  # ---

  defp form_message(violations) do
    lines =
      for %{dashboard: dashboard, panel: panel, rule: rule, labels: labels} <- violations do
        labels = if labels == [], do: "", else: " (#{Enum.join(labels, ", ")})"
        "  #{dashboard}: #{panel} — #{rule}#{labels}: #{Keyword.fetch!(@form_rules, rule)}"
      end

    Enum.join(["форма панелей нарушена (#{@form_norm}):" | lines], "\n")
  end

  defp metric_prefixes(prom_ex) do
    own =
      for {_plugin, plugin_opts} <- plugins(prom_ex),
          prefix = Keyword.get(plugin_opts, :metric_prefix),
          is_list(prefix),
          do: Enum.join(prefix, "_") <> "_"

    Enum.uniq(["#{prom_ex.__otp_app__()}_prom_ex_" | own])
  end

  defp form_sources({name, %{} = dashboard}) when is_binary(name), do: [{name, dashboard}]

  defp form_sources(dir) when is_binary(dir) do
    dir!(dir, "form_violations/3")

    standard = promex_files()

    for path <- Enum.sort(Path.wildcard(Path.join(dir, "*.json"))),
        file = Path.basename(path),
        file not in standard,
        do: {file, Jason.decode!(File.read!(path))}
  end

  defp promex_files do
    :prom_ex
    |> :code.priv_dir()
    |> Path.join("*.json.eex")
    |> Path.wildcard()
    |> Enum.map(&Path.basename(&1, ".eex"))
  end

  defp form_targets(dashboard, prefixes, fixed) do
    for panel <- form_panels(dashboard),
        %{"expr" => expr} = target <- Map.get(panel, "targets", []),
        String.contains?(expr, prefixes) do
      format = Map.get(target, "legendFormat", "")
      %{dashboard: dashboard, panel: panel, expr: expr, legend_format: format, growing: growing(format, fixed)}
    end
  end

  defp form_panels(dashboard),
    do: Enum.flat_map(Map.get(dashboard, "panels", []), &[&1 | Map.get(&1, "panels", [])])

  defp growing(format, fixed) do
    ~r/\{\{\s*(\w+)\s*\}\}/
    |> Regex.scan(format, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
    |> Kernel.--(fixed)
  end

  defp target_violations(%{panel: panel} = target) do
    title = Map.get(panel, "title", "")

    for {rule, _text} <- @form_rules,
        labels <- offending_labels(rule, target),
        do: %{panel: title, rule: rule, labels: labels}
  end

  defp offending_labels(:summary_legend, %{panel: %{"type" => type}, legend_format: format, growing: growing})
       when type in @summaries,
       do: offending(format == "" or growing != [], growing)

  defp offending_labels(:state_timeline, %{panel: %{"type" => "state-timeline"}, growing: growing}),
    do: offending(growing != [], growing)

  defp offending_labels(:timeseries_legend, %{panel: %{"type" => "timeseries"} = panel, expr: expr, growing: growing}),
    do: offending(growing != [] and not state?(expr) and not matches?(panel, "legend", @table_legend), growing)

  defp offending_labels(:state_legend, %{panel: %{"type" => "timeseries"} = panel, expr: expr, growing: growing}) do
    shaped? = matches?(panel, "legend", @state_legend) and matches?(panel, "tooltip", @state_tooltip)
    offending(growing != [] and state?(expr) and not shaped?, growing)
  end

  defp offending_labels(:variable_filter, %{dashboard: dashboard, panel: panel, expr: expr, growing: growing}) do
    if Map.get(panel, "type") in @unfiltered,
      do: [],
      else: for(label <- growing, not filtered?(dashboard, expr, label), do: [label])
  end

  defp offending_labels(_rule, _target), do: []

  defp offending(true, labels), do: [labels]
  defp offending(false, _labels), do: []

  defp state?(expr), do: String.starts_with?(expr, "1 - ")

  defp matches?(panel, option, shape) do
    options = get_in(panel, ["options", option]) || %{}
    Map.take(options, Map.keys(shape)) == shape
  end

  defp filtered?(dashboard, expr, label) do
    variables = get_in(dashboard, ["templating", "list"]) || []

    String.contains?(expr, ~s(#{label}=~"$#{label}")) and
      Enum.any?(variables, &(&1["name"] == label and Map.take(&1, Map.keys(@variable)) == @variable))
  end

  # ===== общее =====

  defp dir!(dir, function) do
    File.dir?(dir) ||
      raise ArgumentError, "Core.PromEx.Dashboards.#{function}: каталог дашбордов не найден: #{inspect(dir)}"
  end

  defp plugins(prom_ex), do: Map.new(prom_ex.plugins(), &plugin_entry/1)

  defp plugin_entry({plugin, plugin_opts}) when is_atom(plugin) and is_list(plugin_opts), do: {plugin, plugin_opts}
  defp plugin_entry(plugin) when is_atom(plugin), do: {plugin, []}
end
