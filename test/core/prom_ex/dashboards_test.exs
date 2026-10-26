defmodule Core.PromEx.DashboardsTest do
  use ExUnit.Case, async: true

  alias Core.Helper
  alias Core.PromEx.Dashboards
  alias Core.PromExFixture

  describe "render/2" do
    test "дашборд outbox — JSON с префиксом, заголовком, тегами и datasource приложения" do
      dashboard = Dashboards.render(PromExFixture.Outbox, :outbox) |> Jason.decode!()

      assert dashboard["title"] == "MyApp - Outbox"
      assert dashboard["tags"] == ["PromEx", "Outbox", "my_app"]
      assert dashboard["uid"] =~ ~r/^[0-9A-F]{32}$/

      exprs = exprs(dashboard)
      assert exprs != []
      assert Enum.all?(exprs, &(&1 =~ "my_app_prom_ex_outbox_"))
      assert Enum.all?(datasources(dashboard), &(&1 == "prometheus"))
    end

    test "пороги стат-панелей — умолчания библиотеки" do
      dashboard = Dashboards.render(PromExFixture.Outbox, :outbox) |> Jason.decode!()

      assert thresholds(dashboard, "Queue depth by status") == [100, 500]
      assert thresholds(dashboard, "Oldest new age") == [30, 120]
      assert thresholds(dashboard, "Expired locks") == [1, 10]
    end

    test "dashboard_assigns/0 перекрывает пороги и префикс, но не заголовок" do
      dashboard = Dashboards.render(PromExFixture.Tuned, :outbox) |> Jason.decode!()

      assert thresholds(dashboard, "Queue depth by status") == [7, 70]
      assert thresholds(dashboard, "Oldest new age") == [30, 120]
      assert Enum.all?(exprs(dashboard), &(&1 =~ "legacy_outbox_"))
      assert Enum.all?(datasources(dashboard), &(&1 == "metrics"))
      assert dashboard["title"] == "OtherApp - Outbox"
      assert dashboard["tags"] == ["PromEx", "Outbox", "other_app"]
    end

    test "префикс и единица длительности — из опций плагина в plugins/0" do
      exprs = exprs(Jason.decode!(Dashboards.render(PromExFixture.Custom, :outbox)))

      assert Enum.all?(exprs, &(&1 =~ "custom_outbox_"))
      assert Enum.any?(exprs, &(&1 =~ "custom_outbox_poller_duration_seconds_bucket"))
    end

    test "uid зависит от приложения" do
      uid = fn prom_ex -> Jason.decode!(Dashboards.render(prom_ex, :outbox))["uid"] end

      refute uid.(PromExFixture.Outbox) == uid.(PromExFixture.Tuned)
      assert uid.(PromExFixture.Outbox) == uid.(PromExFixture.Outbox)
    end

    test "дашборды mq и kafka — заголовок, теги и префикс метрик Core.Mq.PromEx" do
      for {prom_ex, name, label} <- [{PromExFixture.MqReaders, :mq, "MQ"}, {PromExFixture.MqKafka, :kafka, "Kafka"}] do
        dashboard = Dashboards.render(prom_ex, name) |> Jason.decode!()

        assert dashboard["title"] == "MyApp - #{label}"
        assert dashboard["tags"] == ["PromEx", label, "my_app"]
        assert Enum.all?(exprs(dashboard), &(&1 =~ "my_app_prom_ex_mq_"))
      end
    end

    test "префикс и единица длительности mq — из опций Core.Mq.PromEx" do
      dashboard = Jason.decode!(Dashboards.render(PromExFixture.MqStream, :mq))
      exprs = exprs(dashboard)

      assert Enum.all?(exprs, &(&1 =~ "custom_mq_"))
      assert Enum.any?(exprs, &(&1 =~ "custom_mq_publish_duration_seconds_bucket"))

      assert get_in(
               Enum.find(dashboard["panels"], &(&1["title"] == "Publish duration p95")),
               ~w(fieldConfig defaults unit)
             ) == "s"
    end

    test "порог отставания kafka — умолчание библиотеки, перекрывается dashboard_assigns/0" do
      backlog = fn prom_ex -> thresholds(Jason.decode!(Dashboards.render(prom_ex, :kafka)), "Max backlog") end

      assert backlog.(PromExFixture.Outbox) == [1000]
      assert backlog.(PromExFixture.MqKafka) == [5000]
    end

    test "без datasource_id в dashboard_assigns/0 — ArgumentError" do
      assert_raise ArgumentError, ~r/NoDatasource.dashboard_assigns\/0 — ожидается datasource_id/, fn ->
        Dashboards.render(PromExFixture.NoDatasource, :outbox)
      end
    end

    test "дашборд es — префикс, заголовок, пороги отставания и проекции переменной дашборда" do
      dashboard = Dashboards.render(PromExFixture.Outbox, :es) |> Jason.decode!()

      assert dashboard["title"] == "MyApp - Event Sourcing"
      assert dashboard["tags"] == ["PromEx", "Es", "my_app"]
      assert Enum.all?(exprs(dashboard), &(&1 =~ "my_app_prom_ex_es_"))
      assert Enum.any?(exprs(dashboard), &(&1 =~ "my_app_prom_ex_es_projection_duration_milliseconds_bucket"))
      assert thresholds(dashboard, "Projection lag (max)") == [30, 60]
      assert unit(dashboard, "Aggregate load duration p95") == "ms"
      assert variable_names(dashboard) == ~w(job instance projection type)
    end

    test "дашборд cache — префикс, заголовок, пороги hit ratio и кеши переменной дашборда" do
      dashboard = Dashboards.render(PromExFixture.Outbox, :cache) |> Jason.decode!()

      assert dashboard["title"] == "MyApp - Cache"
      assert dashboard["tags"] == ["PromEx", "Cache", "my_app"]
      assert Enum.all?(exprs(dashboard), &(&1 =~ "my_app_prom_ex_cache_"))
      assert thresholds(dashboard, "Hit ratio (5m, min)") == [0.5, 0.9]
      assert variable_names(dashboard) == ~w(job instance cache)
    end

    test "es и cache: префикс и единица длительности — из опций плагинов, пороги — из dashboard_assigns/0" do
      es = Jason.decode!(Dashboards.render(PromExFixture.EsCache, :es))
      cache = Jason.decode!(Dashboards.render(PromExFixture.EsCache, :cache))

      assert Enum.all?(exprs(es), &(&1 =~ "custom_es_"))
      assert Enum.any?(exprs(es), &(&1 =~ "custom_es_aggregate_load_duration_seconds_bucket"))
      assert unit(es, "Aggregate load duration p95") == "s"
      assert thresholds(es, "Projection lag (max)") == [5, 15]
      assert Enum.all?(exprs(cache), &(&1 =~ "custom_cache_"))
      assert thresholds(cache, "Hit ratio (5m, min)") == [0.7, 0.95]
    end
  end

  describe "шаблоны библиотеки" do
    test "каждая метрика в запросах и переменных объявлена плагином" do
      declared = declared_metrics(:my_app)

      for name <- Dashboards.names() do
        json = Dashboards.render(PromExFixture.Outbox, name)
        used = List.flatten(Regex.scan(~r/\bmy_app_prom_ex_([a-z0-9_]+)/, json, capture: :all_but_first))
        undeclared = Enum.reject(Enum.uniq(used), &(&1 in declared))

        assert used != [], "#{name}: в шаблоне нет метрик"
        assert undeclared == [], "#{name}: метрики не объявлены плагинами: #{inspect(undeclared)}"
        assert stray_name_patterns(json, :my_app) == [], "#{name}: регулярка __name__ мимо счётчиков сбоев сбора"
      end
    end

    test "регулярка __name__ сверяется со счётчиками сбоев сбора Core.PromEx.Safe" do
      json = Dashboards.render(PromExFixture.Outbox, :workers)

      assert name_patterns(json) == ["my_app_prom_ex_.+_collect_errors_total"]
      assert stray_name_patterns(json, :my_app) == []

      assert stray_name_patterns(Dashboards.render(PromExFixture.Runtime, :workers), :my_app) ==
               ["legacy_.+_collect_errors_total"]

      assert stray_name_patterns(~s({"expr": "{__name__=~\\"my_app_prom_ex_.+_up\\"}"}), :my_app) ==
               ["my_app_prom_ex_.+_up"]
    end

    test "префикс метрик — только от otp_app приложения" do
      for name <- Dashboards.names() do
        json = Dashboards.render(PromExFixture.Outbox, name)
        prefixes = Enum.uniq(List.flatten(Regex.scan(~r/[a-z0-9_]*?_prom_ex_/, json)))

        assert prefixes == ["my_app_prom_ex_"], "#{name}: чужой префикс #{inspect(prefixes)}"
      end
    end

    test "форма панелей соблюдена" do
      for name <- Dashboards.names() do
        dashboard = Jason.decode!(Dashboards.render(PromExFixture.Outbox, name))
        assert Dashboards.assert_form!(PromExFixture.Outbox, {"#{name}.json", dashboard}) == :ok
      end
    end
  end

  describe "defaults/1" do
    test "дашборд подсистемы входит, если в plugins/0 есть её плагин" do
      assert Dashboards.defaults(PromExFixture.Outbox) == [:outbox]
      assert Dashboards.defaults(PromExFixture.Tuned) == [:outbox]
      assert Dashboards.defaults(PromExFixture.Runtime) == [:workers, :external]
    end

    test "без плагина подсистемы её дашборда нет" do
      assert Dashboards.defaults(PromExFixture.Bare) == []
    end

    test "mq — при stream_readers: или readers: у Core.Mq.PromEx, kafka — при kafka_readers:" do
      assert Dashboards.defaults(PromExFixture.MqStream) == [:mq]
      assert Dashboards.defaults(PromExFixture.MqReaders) == [:mq]
      assert Dashboards.defaults(PromExFixture.MqKafka) == [:kafka]
    end

    test "Core.Mq.PromEx без читателей не даёт ни mq, ни kafka" do
      assert Dashboards.defaults(PromExFixture.MqBare) == []
    end

    test "es и cache — по плагинам Core.Es.PromEx и Core.Cache.PromEx" do
      assert Dashboards.defaults(PromExFixture.EsCache) == [:es, :cache]
    end
  end

  @lag_expr ~s(my_app_prom_ex_es_projection_lag{projection=~"$projection"})
  @lag_unfiltered "my_app_prom_ex_es_projection_lag"
  @table_legend %{
    "displayMode" => "table",
    "placement" => "right",
    "calcs" => ~w(lastNotNull max),
    "sortBy" => "Max",
    "sortDesc" => true
  }
  @down_expr ~s(1 - my_app_prom_ex_workers_up{component=~"$component"})
  @state_legend %{"displayMode" => "list", "placement" => "right", "calcs" => []}
  @state_tooltip %{"mode" => "multi", "hideZeros" => true}

  describe "form_violations/3" do
    test "сводка с фиксированной меткой и legendFormat — норма" do
      summary = panel("stat", "Queue", [target("my_app_prom_ex_outbox_queue_count", "{{status}}")])

      assert Dashboards.form_violations(PromExFixture.Outbox, {"d.json", dashboard([summary])}) == []
    end

    test "сводка с растущей меткой или без legendFormat — нарушение" do
      growing = panel("gauge", "By cache", [target("min(my_app_prom_ex_cache_size)", "{{cache}}")])
      unnamed = panel("bargauge", "Unnamed", [%{"expr" => "max(my_app_prom_ex_workers_up)"}])

      assert Dashboards.form_violations(PromExFixture.Outbox, {"d.json", dashboard([growing, unnamed])}) == [
               %{dashboard: "d.json", panel: "By cache", rule: :summary_legend, labels: ["cache"]},
               %{dashboard: "d.json", panel: "Unnamed", rule: :summary_legend, labels: []}
             ]
    end

    test "state-timeline с фиксированной меткой — норма, с растущей — нарушение" do
      fixed = panel("state-timeline", "Cycles", [target("my_app_prom_ex_outbox_poller_cycles_total", "{{result}}")])
      growing = panel("state-timeline", "Up", [target("my_app_prom_ex_workers_up", "{{component}}")])

      assert violations(dashboard([fixed])) == []
      assert violations(dashboard([growing])) == [violation("Up", :state_timeline, ["component"])]
    end

    test "график с растущей меткой: легенда-таблица справа и фильтр переменной — норма" do
      series = panel("timeseries", "Lag", [target(@lag_expr, "{{projection}}")], %{"legend" => @table_legend})

      assert violations(dashboard([series], [variable("projection")])) == []
    end

    test "график с растущей меткой и легендой-списком — нарушение" do
      legend = %{@table_legend | "displayMode" => "list", "placement" => "bottom"}
      series = panel("timeseries", "Lag", [target(@lag_expr, "{{projection}}")], %{"legend" => legend})

      assert violations(dashboard([series], [variable("projection")])) ==
               [violation("Lag", :timeseries_legend, ["projection"])]
    end

    test "растущая метка без фильтра переменной дашборда — нарушение" do
      unfiltered = panel("timeseries", "Lag", [target(@lag_unfiltered, "{{projection}}")], %{"legend" => @table_legend})
      filtered = panel("timeseries", "Lag 2", [target(@lag_expr, "{{projection}}")], %{"legend" => @table_legend})
      single = Map.merge(variable("projection"), %{"multi" => false, "includeAll" => false})

      assert violations(dashboard([unfiltered], [variable("projection")])) ==
               [violation("Lag", :variable_filter, ["projection"])]

      assert violations(dashboard([filtered])) == [violation("Lag 2", :variable_filter, ["projection"])]
      assert violations(dashboard([filtered], [single])) == [violation("Lag 2", :variable_filter, ["projection"])]
    end

    test "состояние «1 = проблема»: легенда-список без calcs и подсказка multi с hideZeros — норма" do
      options = %{"legend" => @state_legend, "tooltip" => @state_tooltip}
      state = panel("timeseries", "Down", [target(@down_expr, "{{component}}")], options)

      assert violations(dashboard([state], [variable("component")])) == []
    end

    test "состояние с легендой-таблицей или подсказкой с нулями — нарушение" do
      table = panel("timeseries", "Down", [target(@down_expr, "{{component}}")], %{"legend" => @table_legend})
      zeros = %{"legend" => @state_legend, "tooltip" => %{"mode" => "multi", "hideZeros" => false}}
      noisy = panel("timeseries", "Down 2", [target(@down_expr, "{{component}}")], zeros)

      assert violations(dashboard([table, noisy], [variable("component")])) == [
               violation("Down", :state_legend, ["component"]),
               violation("Down 2", :state_legend, ["component"])
             ]
    end

    test "таблица с растущей меткой освобождена" do
      table = panel("table", "Lag", [target(@lag_unfiltered, "{{projection}}")])

      assert violations(dashboard([table])) == []
    end

    test "fixed_labels: расширяет закрытый список фиксированных меток" do
      summary = panel("stat", "By tenant tier", [target("sum by (tier) (my_app_prom_ex_billing_total)", "{{tier}}")])

      assert violations(dashboard([summary])) == [violation("By tenant tier", :summary_legend, ["tier"])]
      assert violations(dashboard([summary]), fixed_labels: ["tier"]) == []
    end

    test "метки экспортёров и метрики без префикса приложения не проверяются" do
      exporter = panel("stat", "Connections", [target("sum by (datname) (pg_stat_activity_count)", "{{datname}}")])
      other = panel("stat", "Other app", [target("other_app_prom_ex_workers_up", "{{component}}")])

      assert violations(dashboard([exporter, other])) == []
    end

    test "панели свёрнутого ряда проверяются" do
      nested = panel("state-timeline", "Up", [target("my_app_prom_ex_workers_up", "{{component}}")])
      row = %{"type" => "row", "title" => "Workers", "panels" => [nested]}

      assert violations(dashboard([row])) == [violation("Up", :state_timeline, ["component"])]
    end

    test "дашборд без templating и панель без title — нарушение, а не отказ" do
      untitled = %{"type" => "timeseries", "targets" => [target(@lag_unfiltered, "{{projection}}")]}
      bare = %{"panels" => [untitled]}

      assert violations(bare) == [
               violation("", :timeseries_legend, ["projection"]),
               violation("", :variable_filter, ["projection"])
             ]

      assert violations(%{}) == []
    end

    @tag :tmp_dir
    test "каталог: нарушения с именем файла, штатные дашборды PromEx вне охвата", %{tmp_dir: dir} do
      growing = panel("state-timeline", "Up", [target("my_app_prom_ex_workers_up", "{{component}}")])
      write!(dir, "domain.json", dashboard([growing]))
      write!(dir, "beam.json", dashboard([growing]))
      File.write!(Path.join(dir, "outbox.json"), Dashboards.render(PromExFixture.Outbox, :outbox))

      assert Dashboards.form_violations(PromExFixture.Outbox, dir) == [
               %{dashboard: "domain.json", panel: "Up", rule: :state_timeline, labels: ["component"]}
             ]
    end

    test "каталога нет — ArgumentError" do
      assert_raise ArgumentError, ~r/form_violations\/3: каталог дашбордов не найден/, fn ->
        Dashboards.form_violations(PromExFixture.Outbox, "no/such/dir")
      end
    end
  end

  describe "assert_form!/3" do
    test "норма — :ok" do
      assert Dashboards.assert_form!(PromExFixture.Outbox, {"d.json", dashboard([])}) == :ok
    end

    test "нарушения — исключение с перечнем: дашборд, панель, правило, метки" do
      growing = panel("state-timeline", "Up", [target("my_app_prom_ex_workers_up", "{{component}}")])
      unnamed = panel("stat", "Unnamed", [%{"expr" => "max(my_app_prom_ex_workers_up)"}])

      error =
        assert_raise Dashboards.FormError, fn ->
          Dashboards.assert_form!(PromExFixture.Outbox, {"d.json", dashboard([growing, unnamed])})
        end

      assert Exception.message(error) =~ "«Форма панелей»"
      assert Exception.message(error) =~ "d.json: Up — state_timeline (component): state-timeline"
      assert Exception.message(error) =~ "d.json: Unnamed — summary_legend: сводка"
    end
  end

  describe "stale/2" do
    @describetag :tmp_dir

    test "выгрузка совпадает с рендером — нарушений нет", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "outbox.json"), Dashboards.render(PromExFixture.Outbox, :outbox))

      assert Dashboards.stale(PromExFixture.Outbox, dir) == []
    end

    test "переформатированная выгрузка — не расхождение", %{tmp_dir: dir} do
      json = Jason.encode!(Jason.decode!(Dashboards.render(PromExFixture.Outbox, :outbox)))
      File.write!(Path.join(dir, "outbox.json"), json <> "\n")

      assert Dashboards.stale(PromExFixture.Outbox, dir) == []
    end

    test "ручная правка — нарушение с именем файла", %{tmp_dir: dir} do
      file = Path.join(dir, "outbox.json")
      dashboard = Dashboards.render(PromExFixture.Outbox, :outbox) |> Jason.decode!()
      File.write!(file, Jason.encode!(%{dashboard | "title" => "Outbox (правка)"}))

      assert Dashboards.stale(PromExFixture.Outbox, dir) == [%{file: file, dashboard: :outbox}]
    end

    test "старый порог — нарушение", %{tmp_dir: dir} do
      file = Path.join(dir, "outbox.json")
      json = Dashboards.render(PromExFixture.Outbox, :outbox)
      File.write!(file, String.replace(json, ~r/("value": )500\b/, "\\g{1}400"))

      assert Dashboards.stale(PromExFixture.Outbox, dir) == [%{file: file, dashboard: :outbox}]
    end

    test "выгрузка другого otp_app — нарушение", %{tmp_dir: dir} do
      file = Path.join(dir, "outbox.json")
      File.write!(file, Dashboards.render(PromExFixture.OtherApp, :outbox))

      assert Dashboards.stale(PromExFixture.Outbox, dir) == [%{file: file, dashboard: :outbox}]
    end

    test "невалидный JSON на месте выгрузки — нарушение", %{tmp_dir: dir} do
      file = Path.join(dir, "outbox.json")
      File.write!(file, "{")

      assert Dashboards.stale(PromExFixture.Outbox, dir) == [%{file: file, dashboard: :outbox}]
    end

    test "каталога нет — ArgumentError", %{tmp_dir: dir} do
      assert_raise ArgumentError, ~r/каталог .*missing не найден/, fn ->
        Dashboards.stale(PromExFixture.Outbox, Path.join(dir, "missing"))
      end
    end

    test "доменные и штатные дашборды не проверяются", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "beam.json"), ~s({"title": "MyApp - BEAM"}))
      File.write!(Path.join(dir, "orders.json"), "{")

      assert Dashboards.stale(PromExFixture.Outbox, dir) == []
    end
  end

  describe "assert_fresh!/2" do
    @describetag :tmp_dir

    test "свежие выгрузки — :ok", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "outbox.json"), Dashboards.render(PromExFixture.Outbox, :outbox))

      assert Dashboards.assert_fresh!(PromExFixture.Outbox, dir) == :ok
    end

    test "расхождение — исключение с файлом и командой переэкспорта", %{tmp_dir: dir} do
      file = Path.join(dir, "outbox.json")
      File.write!(file, Dashboards.render(PromExFixture.Tuned, :outbox))

      error = assert_raise Dashboards.Stale, fn -> Dashboards.assert_fresh!(PromExFixture.Outbox, dir) end

      assert error.message =~ file
      assert error.message =~ "mix core.dashboards.export --module Core.PromExFixture.Outbox --dashboard outbox"
    end
  end

  describe "render/2 — workers" do
    test "процессы, сбои сбора всех плагинов и память контейнера" do
      dashboard = Dashboards.render(PromExFixture.Outbox, :workers) |> Jason.decode!()
      exprs = exprs(dashboard)

      assert dashboard["title"] == "MyApp - Workers"
      assert Enum.any?(exprs, &(&1 =~ "my_app_prom_ex_workers_up{"))
      assert Enum.any?(exprs, &(&1 =~ ~s({__name__=~"my_app_prom_ex_.+_collect_errors_total")))
      assert Enum.any?(exprs, &(&1 =~ "my_app_prom_ex_cgroup_memory_current_bytes{"))
      assert thresholds(dashboard, "Container memory") == [500_000_000, 1_000_000_000]
    end

    test "пороги памяти, шаблон сбоев сбора и префикс cgroup — из dashboard_assigns/0 и plugins/0" do
      dashboard = Dashboards.render(PromExFixture.Runtime, :workers) |> Jason.decode!()
      exprs = exprs(dashboard)

      assert thresholds(dashboard, "Container memory") == [2_000_000_000, 4_000_000_000]
      assert Enum.any?(exprs, &(&1 =~ ~s({__name__=~"legacy_.+_collect_errors_total")))
      assert Enum.any?(exprs, &(&1 =~ "custom_cgroup_memory_current_bytes{"))
      refute Enum.any?(exprs, &(&1 =~ "my_app_prom_ex_cgroup_"))
    end
  end

  describe "render/2 — external" do
    test "система — переменная дашборда, а не литерал" do
      dashboard = Dashboards.render(PromExFixture.Outbox, :external) |> Jason.decode!()
      exprs = exprs(dashboard)
      system = Enum.find(dashboard["templating"]["list"], &(&1["name"] == "system"))

      assert dashboard["title"] == "MyApp - External"
      assert exprs != []
      assert Enum.all?(exprs, &(&1 =~ ~s(system=~"$system")))
      refute Enum.any?(exprs, &(&1 =~ ~s(system=")))
      assert system["query"] =~ "label_values(my_app_prom_ex_external_call_total{"

      assert Map.take(system, ~w(multi includeAll allValue)) == %{
               "multi" => true,
               "includeAll" => true,
               "allValue" => ".*"
             }
    end

    test "префикс и единица длительности — из опций плагина в plugins/0" do
      dashboard = Jason.decode!(Dashboards.render(PromExFixture.Runtime, :external))
      exprs = exprs(dashboard)

      assert Enum.all?(exprs, &(&1 =~ "custom_external_call_"))
      assert Enum.any?(exprs, &(&1 =~ "custom_external_call_duration_seconds_bucket"))
      assert duration_units(dashboard) == ["s", "s"]
      assert duration_units(Jason.decode!(Dashboards.render(PromExFixture.Outbox, :external))) == ["ms", "ms"]
    end
  end

  # ---

  @provider {Kernel, :node, []}
  @plugins [
    {PromEx.Plugins.PromEx, []},
    {Core.Outbox.PromEx, []},
    {Core.Mq.PromEx, stream_readers: @provider, kafka_readers: @provider, dlq_repo: Core.TestRepo},
    {Core.Es.PromEx, projections: @provider, processes: @provider},
    {Core.Cache.PromEx, sizes: @provider},
    {Core.Workers.PromEx, watch: @provider},
    {Core.External.PromEx, []},
    {Core.Cgroup.PromEx, []}
  ]

  defp declared_metrics(otp_app) do
    for metric <- plugin_metrics(otp_app), name <- exported_names(metric) do
      String.replace_prefix(name, "#{otp_app}_prom_ex_", "")
    end
  end

  defp plugin_metrics(otp_app) do
    for {plugin, plugin_opts} <- @plugins,
        callback <- [:event_metrics, :polling_metrics, :manual_metrics],
        Helper.Module.exports?(plugin, callback, 1),
        %{metrics: metrics} <- List.wrap(apply(plugin, callback, [[otp_app: otp_app] ++ plugin_opts])),
        metric <- metrics,
        do: metric
  end

  # Регулярка `{__name__=~"…"}` (якорная, как в PromQL), которая не выбирает ни одной метрики
  # плагинов или выбирает что-то кроме счётчиков сбоев сбора `Core.PromEx.Safe`.
  defp stray_name_patterns(json, otp_app) do
    metrics = plugin_metrics(otp_app)
    names = for metric <- metrics, name <- exported_names(metric), do: name

    collect_errors =
      for %{event_name: [:prom_ex, :plugin, _plugin, :collect, :error]} = metric <- metrics,
          name <- exported_names(metric),
          do: name

    for pattern <- name_patterns(json),
        regex = Regex.compile!("\\A(?:#{pattern})\\z"),
        matched = Enum.filter(names, &Regex.match?(regex, &1)),
        matched == [] or matched -- collect_errors != [],
        do: pattern
  end

  defp name_patterns(json),
    do: List.flatten(Regex.scan(~r/__name__=~\\"(.*?)\\"/, json, capture: :all_but_first))

  defp exported_names(%Telemetry.Metrics.Distribution{name: name}) do
    base = Enum.join(name, "_")
    for suffix <- ~w(_bucket _sum _count), do: base <> suffix
  end

  defp exported_names(%{name: name}), do: [Enum.join(name, "_")]

  defp exprs(dashboard) do
    for panel <- dashboard["panels"], target <- Map.get(panel, "targets", []), do: target["expr"]
  end

  defp thresholds(dashboard, title) do
    %{"fieldConfig" => %{"defaults" => %{"thresholds" => %{"steps" => steps}}}} =
      Enum.find(dashboard["panels"], &(&1["title"] == title and &1["type"] == "stat"))

    for %{"value" => value} <- steps, value != nil, do: value
  end

  defp duration_units(dashboard) do
    for panel <- dashboard["panels"],
        Enum.any?(Map.get(panel, "targets", []), &(&1["expr"] =~ "_duration_")),
        do: panel["fieldConfig"]["defaults"]["unit"]
  end

  defp unit(dashboard, title) do
    %{"fieldConfig" => %{"defaults" => %{"unit" => unit}}} = Enum.find(dashboard["panels"], &(&1["title"] == title))
    unit
  end

  defp variable_names(dashboard), do: for(variable <- dashboard["templating"]["list"], do: variable["name"])

  defp datasources(dashboard) do
    panels = for panel <- dashboard["panels"], panel["type"] != "row", do: panel["datasource"]
    panels ++ for variable <- dashboard["templating"]["list"], do: variable["datasource"]
  end

  defp violations(dashboard, opts \\ []),
    do: Dashboards.form_violations(PromExFixture.Outbox, {"d.json", dashboard}, opts)

  defp violation(panel, rule, labels), do: %{dashboard: "d.json", panel: panel, rule: rule, labels: labels}

  defp dashboard(panels, variables \\ []), do: %{"panels" => panels, "templating" => %{"list" => variables}}

  defp panel(type, title, targets, options \\ %{}),
    do: %{"type" => type, "title" => title, "targets" => targets, "options" => options}

  defp target(expr, format), do: %{"expr" => expr, "legendFormat" => format}

  defp write!(dir, file, dashboard), do: File.write!(Path.join(dir, file), Jason.encode!(dashboard))

  defp variable(name), do: %{"name" => name, "multi" => true, "includeAll" => true, "allValue" => ".*"}
end
