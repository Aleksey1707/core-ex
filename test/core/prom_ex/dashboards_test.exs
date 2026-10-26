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

    test "без datasource_id в dashboard_assigns/0 — ArgumentError" do
      assert_raise ArgumentError, ~r/NoDatasource.dashboard_assigns\/0 — ожидается datasource_id/, fn ->
        Dashboards.render(PromExFixture.NoDatasource, :outbox)
      end
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
      end
    end

    test "префикс метрик — только от otp_app приложения" do
      for name <- Dashboards.names() do
        json = Dashboards.render(PromExFixture.Outbox, name)
        prefixes = Enum.uniq(List.flatten(Regex.scan(~r/[a-z0-9_]*?_prom_ex_/, json)))

        assert prefixes == ["my_app_prom_ex_"], "#{name}: чужой префикс #{inspect(prefixes)}"
      end
    end
  end

  describe "defaults/1" do
    test "дашборд подсистемы входит, если в plugins/0 есть её плагин" do
      assert Dashboards.defaults(PromExFixture.Outbox) == [:outbox]
      assert Dashboards.defaults(PromExFixture.Tuned) == [:outbox]
    end

    test "без плагина подсистемы её дашборда нет" do
      assert Dashboards.defaults(PromExFixture.Bare) == []
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
    for {plugin, plugin_opts} <- @plugins,
        callback <- [:event_metrics, :polling_metrics, :manual_metrics],
        Helper.Module.exports?(plugin, callback, 1),
        %{metrics: metrics} <- List.wrap(apply(plugin, callback, [[otp_app: otp_app] ++ plugin_opts])),
        metric <- metrics,
        name <- exported_names(metric) do
      String.replace_prefix(name, "#{otp_app}_prom_ex_", "")
    end
  end

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

  defp datasources(dashboard) do
    panels = for panel <- dashboard["panels"], panel["type"] != "row", do: panel["datasource"]
    panels ++ for variable <- dashboard["templating"]["list"], do: variable["datasource"]
  end
end
