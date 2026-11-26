defmodule Core.PromEx.Dashboards do
  @moduledoc """
  Дашборды подсистем библиотеки и штатные дашборды PromEx: рендер шаблонов `priv/dashboards/*.json.eex`
  и `:prom_ex` для модуля PromEx приложения (ADR-0089, ADR-0099).

  Рендер идёт через `PromEx.DashboardRenderer`, как у штатных дашбордов PromEx. Параметры шаблона
  собираются по возрастанию приоритета:

  1. умолчания рендерера — префиксы штатных плагинов (`prom_ex_metric_prefix` и др.);
  2. умолчания библиотеки — префикс плагина подсистемы и пороги панелей (таблица ниже);
  3. `dashboard_assigns/0` модуля PromEx приложения.

  `otp_app`, `title` и `uid` строятся от `otp_app` из `use PromEx` приложения и имени дашборда;
  `dashboard_assigns/0` их ключами не меняет: один ключ на все дашборды дал бы им общий заголовок
  и `uid`. Заголовок — `"<имя приложения> - <подпись дашборда>"`, и общая его часть, имя
  приложения, задаётся ключом `app_title` в `dashboard_assigns/0` (по умолчанию
  `Macro.camelize(otp_app)`). На `uid` имя приложения не влияет.
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
  | все | — | `dashboard_refresh` | `"15s"` — интервал обновления дашборда в Grafana |
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
  | | `Core.PromEx.Safe` | `workers_collect_errors_pattern` | `"<otp_app>_prom_ex_.+_collect_errors_total"` |
  | `container` | `Core.Cgroup.PromEx` | `cgroup_metric_prefix` | `metric_prefix:` плагина, `"<otp_app>_prom_ex_cgroup"` |
  | | | `container_memory_warning` / `container_memory_critical` | `500_000_000` / `1_000_000_000` байт |
  | `external` | `Core.External.PromEx` | `external_metric_prefix` | `metric_prefix:` плагина, `"<otp_app>_prom_ex_external"` |
  | | | `external_duration_unit` | `duration_unit:` плагина (мн. ч.) или `"milliseconds"` |
  | | | `external_duration_axis_unit` | единица оси Grafana по `duration_unit:` плагина, `"ms"` |

  Имена проекций, агрегатов и кешей шаблоны не несут: их дают переменные дашборда `projection`,
  `type` и `cache` по меткам метрик.

  Дашборд `workers` входит в набор по `Core.Workers.PromEx`, `container` — по `Core.Cgroup.PromEx`
  (память контейнера). `workers_collect_errors_pattern` — регулярка PromQL по
  `__name__` счётчиков сбоев сбора `<префикс плагина>_collect_errors_total` всех плагинов
  `Core.*.PromEx`: плагин со своим `metric_prefix:` вне `<otp_app>_prom_ex_` требует своей
  регулярки. Система внешнего вызова у дашборда `external` — переменная `system`.

  Штатные дашборды PromEx (`standard/0`) — `application`, `beam`, `phoenix`, `ecto`, `oban` — core
  рендерит из шаблонов `:prom_ex` с assigns приложения и приводит к Grafana 11: панели `graph`
  мигрируют в `timeseries` (`migrate_graph_panels/1`), снимаются мёртвые аннотации и демо-значения
  переменных, `refresh` берётся из `dashboard_refresh`. Штатный дашборд входит в `defaults/1` по
  наличию его плагина в `plugins/0`. `uid` штатного дашборда — как у подсистемного: от `otp_app` и
  имени, а не от `title` и имени модуля PromEx.

  Выгрузку в каталог дашбордов приложения делает `mix core.dashboards.export`; совпадение выгрузок
  с текущим рендером проверяют `stale/2` и вариант для теста `assert_fresh!/2`, форму панелей всех
  дашбордов каталога — `form_violations/3` и `assert_form!/3`, выгрузку вне набора `defaults/1`
  (файл остался после смены `plugins/0`) — `surplus/2` и `assert_no_surplus!/2`.
  """

  use Core.Options

  alias PromEx.DashboardRenderer

  defmodule Stale do
    @moduledoc "Выгрузка дашборда разошлась с рендером (`assert_fresh!/2`)."

    defexception [:message]
  end

  defmodule FormError do
    @moduledoc """
    Форма панелей нарушена (`assert_form!/3`): `message` — читаемый перечень, `violations` —
    нарушения в форме `form_violations/3`.
    """

    defexception message: "форма панелей нарушена", violations: []
  end

  defmodule Surplus do
    @moduledoc "Выгрузка дашборда вне набора `defaults/1` (`assert_no_surplus!/2`)."

    defexception [:message]
  end

  @typedoc "Имя дашборда подсистемы библиотеки; файл выгрузки — `<имя>.json`."
  @type name :: :outbox | :mq | :kafka | :es | :cache | :workers | :container | :external

  @typedoc "Имя штатного дашборда PromEx; файл выгрузки — `<имя>.json`."
  @type standard_name :: :application | :beam | :phoenix | :ecto | :oban

  @typedoc "Имя любого дашборда, который выгружает core."
  @type dashboard_name :: name() | standard_name()

  @typedoc "Выгрузка `file` дашборда `dashboard`."
  @type dashboard_export :: %{file: Path.t(), dashboard: dashboard_name()}

  @typedoc "Выгрузка `file` дашборда `dashboard`, разошедшаяся с рендером."
  @type stale_export :: dashboard_export()

  @typedoc "Выгрузка `file` дашборда `dashboard`, которого нет в наборе `defaults/1`."
  @type surplus_export :: dashboard_export()

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
      thresholds: []
    },
    container: %{
      plugin: Core.Cgroup.PromEx,
      label: "Container",
      prefix: :cgroup,
      duration?: false,
      thresholds: [container_memory_warning: 500_000_000, container_memory_critical: 1_000_000_000]
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
  @standard [
    application: %{plugin: PromEx.Plugins.Application, label: "PromEx Application Dashboard"},
    beam: %{plugin: PromEx.Plugins.Beam, label: "PromEx Beam Dashboard"},
    phoenix: %{plugin: PromEx.Plugins.Phoenix, label: "PromEx Phoenix Dashboard"},
    ecto: %{plugin: PromEx.Plugins.Ecto, label: "PromEx Ecto Dashboard"},
    oban: %{plugin: PromEx.Plugins.Oban, label: "PromEx Oban Dashboard"}
  ]
  @standard_names Keyword.keys(@standard)
  @all_names @names ++ @standard_names
  @assign_keys for {_name, %{prefix: prefix}} <- @dashboards,
                   kind <- ~w(metric_prefix duration_unit duration_axis_unit)a,
                   into: %{},
                   do: {{prefix, kind}, :"#{prefix}_#{kind}"}

  # ===== набор =====

  @doc "Все дашборды подсистем библиотеки."
  @spec names() :: [name()]

  def names, do: @names

  @doc "Все штатные дашборды PromEx, которые выгружает core."
  @spec standard() :: [standard_name()]

  def standard, do: @standard_names

  @doc """
  Набор дашбордов по умолчанию для модуля PromEx приложения — по его `plugins/0`.

  Дашборд подсистемы входит в набор, если в `plugins/0` есть плагин его подсистемы. Дашборды
  `Core.Mq.PromEx` требуют ещё и опции плагина: `mq` — `stream_readers:`, `kafka` — `kafka_readers:`;
  иначе в Grafana лёг бы дашборд транспорта, которого у приложения нет. Старый ключ `readers:` плагин
  не читает, и `mq` по нему не входит.

  Штатный дашборд PromEx входит по наличию своего плагина: `PromEx.Plugins.Application`, `Beam`,
  `Phoenix`, `Ecto`, `Oban`.
  """
  @spec defaults(module()) :: [dashboard_name()]

  def defaults(prom_ex) when is_atom(prom_ex) do
    plugins = plugins(prom_ex)
    subsystem_defaults(plugins) ++ standard_defaults(plugins)
  end

  # ---

  defp subsystem_defaults(plugins) do
    for {name, %{plugin: plugin} = dashboard} <- @dashboards,
        plugin_opts = Map.get(plugins, plugin),
        is_list(plugin_opts) and options_given?(dashboard, plugin_opts),
        do: name
  end

  defp standard_defaults(plugins) do
    for {name, %{plugin: plugin}} <- @standard, Map.has_key?(plugins, plugin), do: name
  end

  # ---

  defp options_given?(%{options: options}, plugin_opts), do: Enum.any?(options, &Keyword.has_key?(plugin_opts, &1))
  defp options_given?(%{}, _plugin_opts), do: true

  # ===== рендер =====

  @doc """
  Отрендерить дашборд `name` — подсистемы библиотеки или штатный PromEx — для модуля PromEx
  приложения; JSON выгрузки.

  Штатный дашборд рендерится из шаблона `:prom_ex` и приводится к Grafana 11: панели `graph`
  мигрируют в `timeseries`, снимаются мёртвые аннотации, `refresh` берётся из `dashboard_refresh`.

  `ArgumentError` — в `dashboard_assigns/0` нет `datasource_id`, `app_title` не непустая строка,
  параметры дали невалидный JSON или шаблона PromEx нет.
  """
  @spec render(module(), dashboard_name()) :: String.t()

  def render(prom_ex, name) when is_atom(prom_ex) and (name in @names or name in @standard_names) do
    if name in @standard_names, do: render_standard(prom_ex, name), else: render_subsystem(prom_ex, name)
  end

  # ---

  defp render_subsystem(prom_ex, name) do
    otp_app = prom_ex.__otp_app__()
    %{label: label} = dashboard = Keyword.fetch!(@dashboards, name)
    plugins = plugins(prom_ex)

    :core
    |> DashboardRenderer.build("dashboards/#{name}.json", otp_app)
    |> DashboardRenderer.merge_assigns(library_assigns(dashboard, otp_app, plugins))
    |> DashboardRenderer.merge_assigns(neighbour_assigns(name, otp_app, plugins))
    |> DashboardRenderer.merge_assigns(dashboard_refresh())
    |> DashboardRenderer.merge_assigns(prom_ex.dashboard_assigns())
    |> merge_identity(prom_ex, name, label)
    |> check_datasource!(prom_ex)
    |> render_template()
    |> DashboardRenderer.decode_dashboard()
    |> rendered!(prom_ex, name)
  end

  defp render_standard(prom_ex, name) do
    otp_app = prom_ex.__otp_app__()
    %{label: label} = Keyword.fetch!(@standard, name)

    dashboard =
      :prom_ex
      |> DashboardRenderer.build("#{name}.json", otp_app)
      |> template!(prom_ex, name)
      |> DashboardRenderer.merge_assigns(dashboard_refresh())
      |> DashboardRenderer.merge_assigns(prom_ex.dashboard_assigns())
      |> merge_identity(prom_ex, name, label)
      |> check_datasource!(prom_ex)
      |> render_template()
      |> DashboardRenderer.decode_dashboard()

    dashboard
    |> decoded!(prom_ex, name)
    |> migrate_graph_panels()
    |> standard_fixes(name, dashboard.assigns)
    |> Jason.encode!()
  end

  defp dashboard_refresh, do: [dashboard_refresh: "15s"]

  defp template!(%DashboardRenderer{valid_file?: false, error: error}, prom_ex, name) do
    raise ArgumentError,
          "Core.PromEx.Dashboards.render/2: шаблон штатного дашборда #{name} для #{inspect(prom_ex)} " <>
            "не найден: #{inspect(error)}"
  end

  defp template!(%DashboardRenderer{} = dashboard, _prom_ex, _name), do: dashboard

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

  # Параметры дашборда, не выводимые из плагина подсистемы: регулярка счётчиков сбоев сбора.
  defp neighbour_assigns(:workers, otp_app, _plugins) do
    [workers_collect_errors_pattern: "#{otp_app}_prom_ex_.+_collect_errors_total"]
  end

  defp neighbour_assigns(_name, _otp_app, _plugins), do: []

  defp assign_key(prefix, kind), do: Map.fetch!(@assign_keys, {prefix, kind})

  defp merge_identity(%DashboardRenderer{assigns: assigns} = dashboard, prom_ex, name, label) do
    otp_app = prom_ex.__otp_app__()

    DashboardRenderer.merge_assigns(dashboard,
      otp_app: otp_app,
      title: "#{app_title!(assigns, otp_app, prom_ex)} - #{label}",
      uid: Base.encode16(:crypto.hash(:md5, "#{otp_app}/#{name}"))
    )
  end

  defp app_title!(assigns, otp_app, prom_ex) do
    case Keyword.fetch(assigns, :app_title) do
      :error ->
        Macro.camelize(Atom.to_string(otp_app))

      {:ok, <<_, _::binary>> = app_title} ->
        app_title

      {:ok, other} ->
        raise ArgumentError,
              "Core.PromEx.Dashboards.render/2: #{inspect(prom_ex)}.dashboard_assigns/0 — ожидается " <>
                "app_title: имя приложения непустой строкой, получено #{inspect(other)}"
    end
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

  defp rendered!(%DashboardRenderer{valid_json?: true, rendered_file: json}, _prom_ex, _name)
       when is_binary(json),
       do: json

  defp rendered!(%DashboardRenderer{error: error}, prom_ex, name), do: render_error!(error, prom_ex, name)

  defp decoded!(%DashboardRenderer{valid_json?: true, decoded_dashboard: decoded}, _prom_ex, _name),
    do: decoded

  defp decoded!(%DashboardRenderer{error: error}, prom_ex, name), do: render_error!(error, prom_ex, name)

  defp render_error!(error, prom_ex, name) do
    raise ArgumentError,
          "Core.PromEx.Dashboards.render/2: дашборд #{name} для #{inspect(prom_ex)} не отрендерился: " <>
            inspect(error)
  end

  defp standard_fixes(dashboard, name, assigns) do
    dashboard
    |> fix_panels(name)
    |> drop_tag_annotations()
    |> Map.put("refresh", Keyword.fetch!(assigns, :dashboard_refresh))
  end

  defp fix_panels(dashboard, :beam), do: update_panels(dashboard, &fix_beam_panel/1)
  defp fix_panels(dashboard, :phoenix), do: update_panels(dashboard, &fix_phoenix_panel/1)

  defp fix_panels(dashboard, :oban) do
    dashboard
    |> update_panels(&fix_oban_panel/1)
    |> blank_oban_variables()
  end

  defp fix_panels(dashboard, _name), do: dashboard

  defp update_panels(%{"panels" => panels} = dashboard, fun) when is_list(panels),
    do: %{dashboard | "panels" => Enum.map(panels, &update_panel(&1, fun))}

  defp update_panels(dashboard, _fun), do: dashboard

  defp update_panel(panel, fun) do
    panel = fun.(panel)

    case panel do
      %{"panels" => panels} when is_list(panels) ->
        %{panel | "panels" => Enum.map(panels, &update_panel(&1, fun))}

      panel ->
        panel
    end
  end

  @otp_version_panel "OTP Major Version"
  @phoenix_http_panels ["Average HTTP Request Time", "Average HTTP Response Size"]
  @oban_poll_interval "_init_poll_interval_milliseconds"

  defp fix_beam_panel(%{"title" => @otp_version_panel, "type" => "stat"} = panel) do
    Map.put(panel, "transformations", [
      %{"id" => "labelsToFields", "options" => %{}},
      %{"id" => "filterFieldsByName", "options" => %{"include" => %{"pattern" => "/^version$/"}}}
    ])
  end

  defp fix_beam_panel(panel), do: panel

  defp fix_phoenix_panel(%{"title" => title, "targets" => targets} = panel) when title in @phoenix_http_panels do
    targets =
      Enum.map(targets, fn
        %{"expr" => expr} = target ->
          %{target | "expr" => String.replace(expr, "by(path, status)", "by(method, path, status)")}

        target ->
          target
      end)

    %{panel | "targets" => targets}
  end

  defp fix_phoenix_panel(panel), do: panel

  defp fix_oban_panel(%{"title" => "Oban Time Limit Settings"} = panel) do
    panel
    |> update_in(["fieldConfig", "overrides"], &drop_poll_interval_mapping/1)
    |> update_in(["targets"], &drop_poll_interval_expr/1)
  end

  defp fix_oban_panel(panel), do: panel

  defp drop_poll_interval_mapping(overrides) when is_list(overrides) do
    Enum.map(overrides, &drop_poll_interval_property/1)
  end

  defp drop_poll_interval_mapping(overrides), do: overrides

  defp drop_poll_interval_property(override) do
    update_in(override, ["properties"], fn properties ->
      Enum.map(properties, &drop_poll_interval_mappings/1)
    end)
  end

  defp drop_poll_interval_mappings(%{"id" => "mappings", "value" => mappings} = property)
       when is_list(mappings),
       do: Map.put(property, "value", Enum.reject(mappings, &poll_interval_mapping?/1))

  defp drop_poll_interval_mappings(property), do: property

  defp drop_poll_interval_expr(targets) when is_list(targets) do
    Enum.map(targets, fn
      %{"expr" => expr} = target ->
        Map.put(target, "expr", Regex.replace(~r/\|[\w]+#{@oban_poll_interval}/, expr, ""))

      target ->
        target
    end)
  end

  defp drop_poll_interval_expr(targets), do: targets

  defp poll_interval_mapping?(%{"value" => value}) when is_binary(value),
    do: String.ends_with?(value, @oban_poll_interval)

  defp poll_interval_mapping?(_mapping), do: false

  defp blank_oban_variables(%{"templating" => %{"list" => variables}} = dashboard) when is_list(variables) do
    variables =
      Enum.map(variables, fn
        %{"name" => name} = variable when name in ["job", "instance"] -> Map.put(variable, "current", %{})
        variable -> variable
      end)

    put_in(dashboard, ["templating", "list"], variables)
  end

  defp blank_oban_variables(dashboard), do: dashboard

  defp drop_tag_annotations(%{"annotations" => %{"list" => list}} = dashboard) when is_list(list) do
    put_in(dashboard, ["annotations", "list"], Enum.reject(list, &(&1["type"] == "tags")))
  end

  defp drop_tag_annotations(dashboard), do: dashboard

  # ===== миграция панелей =====

  @legacy_graph_keys ~w(aliasColors bars dashLength dashes fill fillGradient hiddenSeries legend
                        lines linewidth nullPointMode percentage pluginVersion pointradius points
                        renderer seriesOverrides spaceLength stack steppedLine thresholds timeFrom
                        timeRegions timeShift tooltip xaxis yaxes yaxis)

  @graph_legend %{
    "showLegend" => true,
    "displayMode" => "table",
    "placement" => "right",
    "calcs" => ~w(lastNotNull max),
    "sortBy" => "Max",
    "sortDesc" => true
  }

  @doc """
  Мигрировать панели `graph` дашборда в `timeseries` Grafana 11 — декодированный JSON дашборда.

  Панель `graph` теряет angular-ключи (`yaxes`, `xaxis`, `legend`, `tooltip`, `lines`, `fill`,
  `points`, `bars`, `thresholds` и др.); единица оси (`yaxes[0].format`) переносится в
  `fieldConfig.defaults.unit`, `lineWidth`, `fillOpacity`, `drawStyle` и `showPoints` — в
  `fieldConfig.defaults.custom`, легенда становится таблицей справа (`lastNotNull`, `max`,
  сортировка по `max` desc), подсказка — `multi`. Панели других типов не меняются; повторный вызов
  на мигрированном дашборде ничего не меняет.
  """
  @spec migrate_graph_panels(map()) :: map()

  def migrate_graph_panels(%{"panels" => panels} = dashboard) when is_list(panels) do
    %{dashboard | "panels" => Enum.map(panels, &migrate_panel/1)}
  end

  def migrate_graph_panels(dashboard), do: dashboard

  # ---

  defp migrate_panel(%{"type" => "graph"} = panel) do
    panel
    |> put_timeseries_field_config()
    |> Map.drop(@legacy_graph_keys)
    |> Map.put("type", "timeseries")
    |> put_timeseries_options()
  end

  defp migrate_panel(%{"panels" => panels} = panel) when is_list(panels) do
    %{panel | "panels" => Enum.map(panels, &migrate_panel/1)}
  end

  defp migrate_panel(panel), do: panel

  defp put_timeseries_field_config(panel) do
    axis = List.first(Map.get(panel, "yaxes", [])) || %{}
    field_config = Map.get(panel, "fieldConfig") || %{}
    defaults = Map.get(field_config, "defaults") || %{}
    custom = Map.get(defaults, "custom") || %{}

    defaults =
      defaults
      |> Map.put("unit", Map.get(axis, "format", "short"))
      |> Map.put("custom", Map.merge(custom, timeseries_custom(panel)))

    Map.put(panel, "fieldConfig", Map.put(field_config, "defaults", defaults))
  end

  defp timeseries_custom(panel) do
    %{
      "lineWidth" => Map.get(panel, "linewidth", 1),
      "fillOpacity" => Map.get(panel, "fill", 0) * 10,
      "drawStyle" => if(Map.get(panel, "bars", false), do: "bars", else: "line"),
      "showPoints" => if(Map.get(panel, "points", false), do: "always", else: "never")
    }
  end

  defp put_timeseries_options(panel) do
    options =
      panel
      |> Map.get("options", %{})
      |> Map.drop(["alertThreshold"])
      |> Map.put("legend", @graph_legend)
      |> Map.put("tooltip", %{"mode" => "multi"})

    Map.put(panel, "options", options)
  end

  # ===== свежесть выгрузок =====

  @doc """
  Выгрузки дашбордов подсистем библиотеки и штатных дашбордов PromEx в каталоге `dir`, разошедшиеся
  с текущим рендером для модуля PromEx приложения; пустой список — все выгрузки свежие.

  Выгрузка узнаётся по имени файла: `<имя>.json` для каждого имени из `names/0` и `standard/0` — так
  её называет `mix core.dashboards.export`. Другие файлы каталога — доменные дашборды — не
  проверяются; дашборд, которого в каталоге нет, нарушением не считается. Файл сравнивается с
  рендером как JSON: форматирование и перевод строки в конце не важны, ручная правка, старый
  порог, выгрузка другого `otp_app`, невалидный JSON или нечитаемый файл — расхождение.

  `ArgumentError` — каталога `dir` нет: опечатка в пути иначе молча дала бы пустой список.
  """
  @spec stale(module(), Path.t()) :: [stale_export()]

  def stale(prom_ex, dir) when is_atom(prom_ex) and is_binary(dir) do
    dir!(dir, "stale/2")

    for name <- @all_names,
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

  # ===== лишние выгрузки =====

  @doc """
  Выгрузки каталога `dir` с именем дашборда из `names/0` или `standard/0`, которых нет в наборе
  `defaults/1` модуля PromEx приложения; пустой список — лишних выгрузок нет.

  Класс ошибки — файл остался после смены `plugins/0`: выключили плагин подсистемы, сняли опцию
  читателей или убрали штатный плагин PromEx, а выгрузка в каталоге осталась. Дашборд из набора, но
  отсутствующий в каталоге, лишним не считается. `ArgumentError` — каталога `dir` нет.
  """
  @spec surplus(module(), Path.t()) :: [surplus_export()]

  def surplus(prom_ex, dir) when is_atom(prom_ex) and is_binary(dir) do
    dir!(dir, "surplus/2")
    defaults = defaults(prom_ex)

    for name <- @all_names,
        name not in defaults,
        file = Path.join(dir, "#{name}.json"),
        File.regular?(file),
        do: %{file: file, dashboard: name}
  end

  @doc """
  Вариант `surplus/2` для теста приложения: `:ok` или `Core.PromEx.Dashboards.Surplus` с перечнем
  выгрузок вне набора.
  """
  @spec assert_no_surplus!(module(), Path.t()) :: :ok

  def assert_no_surplus!(prom_ex, dir) when is_atom(prom_ex) and is_binary(dir) do
    case surplus(prom_ex, dir) do
      [] -> :ok
      exports -> raise Surplus, surplus_message(exports, prom_ex)
    end
  end

  # ---

  defp surplus_message(exports, prom_ex) do
    lines = for %{file: file, dashboard: name} <- exports, do: "  #{file}: дашборд #{name} вне набора"

    Enum.join(
      [
        "Core.PromEx.Dashboards.assert_no_surplus!/2: выгрузки дашбордов, которых нет в наборе " <>
          "#{inspect(prom_ex)} — удалить файл или вернуть плагин и его опции в plugins/0:"
        | lines
      ],
      "\n"
    )
  end

  # ===== форма панелей =====

  @fixed_labels ~w(result outcome status error op channel kind collector reason)
  @conditional_fixed_labels ~w(operation)
  @ignored_labels ~w(le job instance quantile)
  @aggregation_ops ~w(sum min max avg count group stddev stdvar count_values quantile)
  @aggregation ~r/\b(#{Enum.join(@aggregation_ops, "|")})\s*(?:(by|without)\s*\(([^)]*)\))?\s*\(/
  @summaries ~w(stat gauge bargauge)
  @form_rules [
    summary_legend: "сводка без legendFormat (в том числе null) или с растущей меткой в нём",
    state_timeline: "state-timeline с растущей меткой",
    timeseries_legend: "легенда графика — не таблица справа: lastNotNull, max, сортировка по max desc",
    state_legend: "состояние «1 = проблема»: легенда не список справа без calcs или подсказка не multi с hideZeros",
    variable_filter:
      ~s(график с растущей меткой без фильтра переменной дашборда: label=~"$label", multi, All, allValue ".*")
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
  выгрузка штатного дашборда, её форму задаёт PromEx и миграция legacy-панелей core, и проверка его
  пропускает; доменный дашборд с таким именем выпал бы из проверки вместе с ним, поэтому имя шаблона
  PromEx ему не дают.

  Проверяются запросы панелей (и панелей свёрнутых рядов) с метриками плагинов модуля PromEx:
  префикс `<otp_app>_prom_ex_` (умолчание `PromEx.metric_prefix/2` у каждого плагина) и
  `metric_prefix:` плагинов из `plugins/0`. Метки экспортёров (`datname`, `mountpoint`) задаёт
  окружение, их запросы вне охвата. Метки панели берутся из `legendFormat` и `by (...)` запроса;
  явный `legendFormat: null` — та же пустая легенда. Растущая — любая вне закрытого списка
  фиксированных `#{Enum.join(@fixed_labels, ", ")}` и `fixed_labels:`; `operation` фиксирована, только
  если запрос задаёт `system` матчером (`=`, `!=`, `=~`, `!~`); `le`, `job`, `instance` и `quantile`
  — метки гистограмм и окружения — растущими не считаются. `without` и `on` не разбираются.

  | Правило | Нарушение |
  |---|---|
  | `:summary_legend` | `stat` / `gauge` / `bargauge` без `legendFormat` (в том числе `null`) или с растущей меткой в нём |
  | `:state_timeline` | `state-timeline` с растущей меткой |
  | `:timeseries_legend` | `timeseries` с растущей меткой: легенда не таблица справа (`lastNotNull`, `max`, `Max`↓) |
  | `:state_legend` | состояние `1 - …`: легенда не список справа без `calcs`, подсказка не `multi` + `hideZeros` |
  | `:variable_filter` | `timeseries` с растущей меткой без `<метка>=~"$<метка>"` и переменной `multi`, All, `allValue: ".*"` |

  `:variable_filter` проверяется только у `timeseries`: `table` прокручивает строки, у сводки и
  `state-timeline` растущая метка — уже нарушение их правила, остальные типы фильтра не требуют.

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
      format = Map.get(target, "legendFormat") || ""
      %{dashboard: dashboard, panel: panel, expr: expr, legend_format: format, growing: growing(expr, format, fixed)}
    end
  end

  defp form_panels(dashboard),
    do: Enum.flat_map(Map.get(dashboard, "panels", []), &[&1 | Map.get(&1, "panels", [])])

  defp growing(expr, format, fixed) do
    fixed = if system?(expr), do: fixed ++ @conditional_fixed_labels, else: fixed

    (legend_labels(format) ++ group_labels(expr))
    |> Enum.uniq()
    |> Kernel.--(fixed)
    |> Kernel.--(@ignored_labels)
  end

  defp legend_labels(format) do
    ~r/\{\{\s*(\w+)\s*\}\}/
    |> Regex.scan(format, capture: :all_but_first)
    |> List.flatten()
  end

  defp group_labels(expr) do
    aggregations = aggregations(expr)

    for [{start, _len}, {labels_start, labels_len}] <-
          Regex.scan(~r/\bby\s*\(([^)]*)\)/, expr, return: :index),
        not overridden?(aggregations, start),
        label <- split_labels(binary_part(expr, labels_start, labels_len)),
        do: label
  end

  # В `count(max by (component, topic) (…))` и `sum by (topic) (max by (…) (…))` итоговые метки
  # задаёт внешняя агрегация: без `by` она их снимает, с `by` — заменяет своими.
  defp overridden?(aggregations, pos) do
    Enum.any?(aggregations, fn %{open: open, close: close, grouping: grouping} ->
      open < pos and pos < close and grouping != :without
    end)
  end

  defp aggregations(expr) do
    for [{start, len}, _op | rest] <- Regex.scan(@aggregation, expr, return: :index) do
      open = start + len - 1

      %{open: open, grouping: grouping(expr, rest), close: close_paren(expr, open)}
    end
  end

  defp grouping(_expr, []), do: nil

  defp grouping(expr, [{start, len} | _]),
    do: if(binary_part(expr, start, len) == "without", do: :without, else: :by)

  defp close_paren(expr, open) do
    expr
    |> :binary.bin_to_list()
    |> Enum.with_index()
    |> Enum.reduce_while(0, fn {byte, pos}, depth ->
      cond do
        pos <= open -> {:cont, depth}
        byte == ?( -> {:cont, depth + 1}
        byte == ?) and depth == 0 -> {:halt, pos}
        byte == ?) -> {:cont, depth - 1}
        true -> {:cont, depth}
      end
    end)
  end

  defp split_labels(labels) do
    labels
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp system?(expr), do: Regex.match?(~r/\bsystem\s*(?:=~|!~|!=|=)\s*/, expr)

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

  defp offending_labels(:variable_filter, %{
         dashboard: dashboard,
         panel: %{"type" => "timeseries"},
         expr: expr,
         growing: growing
       }) do
    for label <- growing, not filtered?(dashboard, expr, label), do: [label]
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
