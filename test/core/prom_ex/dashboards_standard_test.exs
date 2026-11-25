defmodule Core.PromEx.DashboardsStandardTest do
  @moduledoc """
  Штатные дашборды PromEx: рендер из шаблонов `:prom_ex`, миграция legacy-панелей и golden-выгрузки.

  `UPDATE_DASHBOARDS=1 mix test test/core/prom_ex/dashboards_standard_test.exs` перезаписывает
  golden-выгрузки в `test/support/fixtures/dashboards`.
  """

  use ExUnit.Case, async: true

  alias Core.PromEx.Dashboards
  alias Core.PromExFixture

  @golden Path.expand("../../support/fixtures/dashboards", __DIR__)

  test "каждый штатный дашборд совпадает с golden-выгрузкой" do
    for name <- Dashboards.standard() do
      rendered = Dashboards.render(PromExFixture.Standard, name) |> Jason.decode!()
      golden = Path.join(@golden, "#{name}.json")

      if System.get_env("UPDATE_DASHBOARDS") == "1" do
        File.write!(golden, Jason.encode!(rendered, pretty: true) <> "\n")
      else
        golden =
          golden
          |> File.read!()
          |> Jason.decode!()

        assert rendered == golden, "#{name}: выгрузка разошлась с golden"
      end
    end
  end

  test "в штатных дашбордах не остаётся панелей graph, мигрированы все 36" do
    panels =
      for name <- Dashboards.standard(),
          dashboard = Jason.decode!(Dashboards.render(PromExFixture.Standard, name)),
          panel <- panels(dashboard),
          do: {name, panel}

    assert for({name, panel} <- panels, panel["type"] == "graph", do: {name, panel["title"]}) == []
    assert Enum.count(panels, fn {_name, panel} -> panel["type"] == "timeseries" end) == 36
  end

  test "заголовок и uid — от otp_app и имени, а не от title и модуля PromEx" do
    dashboard = Jason.decode!(Dashboards.render(PromExFixture.Standard, :beam))

    assert dashboard["title"] == "MyApp - PromEx Beam Dashboard"
    assert dashboard["uid"] == Base.encode16(:crypto.hash(:md5, "my_app/beam"))
    assert dashboard["tags"] == ["PromEx", "BEAM", "my_app"]
  end

  test "мёртвые аннотации PromEx сняты, refresh — из assigns" do
    dashboard = Jason.decode!(Dashboards.render(PromExFixture.Standard, :beam))

    assert Enum.map(dashboard["annotations"]["list"], & &1["type"]) == ["dashboard"]
    assert dashboard["refresh"] == "15s"
    assert Jason.decode!(Dashboards.render(PromExFixture.Tuned, :beam))["refresh"] == "30s"
  end

  test "beam: OTP Major Version читает метку version" do
    panel = panel(Jason.decode!(Dashboards.render(PromExFixture.Standard, :beam)), "OTP Major Version")

    assert [%{"id" => "labelsToFields"}, %{"id" => "filterFieldsByName"}] = panel["transformations"]
    assert get_in(panel, ["transformations", Access.at(1), "options", "include"]) == %{"pattern" => "/^version$/"}
  end

  test "phoenix: method в агрегациях среднего времени и размера" do
    dashboard = Jason.decode!(Dashboards.render(PromExFixture.Standard, :phoenix))

    for title <- ["Average HTTP Request Time", "Average HTTP Response Size"] do
      exprs = Enum.map(panel(dashboard, title)["targets"], & &1["expr"])

      assert exprs != []
      assert Enum.all?(exprs, &String.contains?(&1, "by(method, path, status)"))
    end
  end

  test "oban: метрики poll interval нет, демо-значения переменных сняты" do
    json = Dashboards.render(PromExFixture.Standard, :oban)
    variables = Jason.decode!(json)["templating"]["list"]

    refute json =~ "init_poll_interval_milliseconds"

    assert for(%{"name" => name} = variable <- variables, name in ["job", "instance"], do: variable["current"]) ==
             [%{}, %{}]
  end

  describe "migrate_graph_panels/1" do
    test "graph-панель: единица оси, линия, заливка, легенда и подсказка" do
      graph = %{
        "type" => "graph",
        "title" => "P",
        "id" => 1,
        "datasource" => "prom",
        "gridPos" => %{"x" => 0, "y" => 0, "w" => 12, "h" => 8},
        "targets" => [%{"expr" => "up", "refId" => "A"}],
        "description" => "d",
        "fill" => 1,
        "linewidth" => 2,
        "bars" => false,
        "points" => false,
        "nullPointMode" => "null",
        "stack" => false,
        "percentage" => false,
        "lines" => true,
        "legend" => %{"show" => true},
        "tooltip" => %{"shared" => true},
        "thresholds" => [],
        "timeFrom" => nil,
        "timeShift" => nil,
        "xaxis" => %{"mode" => "time"},
        "yaxes" => [%{"format" => "ms", "label" => "Response Time"}, %{"format" => "short"}],
        "yaxis" => %{"align" => true},
        "aliasColors" => %{},
        "seriesOverrides" => [],
        "pluginVersion" => "7.1.3",
        "options" => %{"alertThreshold" => true},
        "fieldConfig" => %{"defaults" => %{"custom" => %{}, "unit" => "short"}, "overrides" => []}
      }

      migrated =
        Dashboards.migrate_graph_panels(%{"panels" => [graph]})
        |> Map.fetch!("panels")
        |> hd()

      assert migrated["type"] == "timeseries"
      assert migrated["title"] == "P"
      assert migrated["description"] == "d"
      assert migrated["datasource"] == "prom"
      assert migrated["targets"] == graph["targets"]
      assert migrated["fieldConfig"]["defaults"]["unit"] == "ms"

      assert migrated["fieldConfig"]["defaults"]["custom"] == %{
               "lineWidth" => 2,
               "fillOpacity" => 10,
               "drawStyle" => "line",
               "showPoints" => "never"
             }

      assert migrated["options"] == %{
               "legend" => %{
                 "showLegend" => true,
                 "displayMode" => "table",
                 "placement" => "right",
                 "calcs" => ["lastNotNull", "max"],
                 "sortBy" => "Max",
                 "sortDesc" => true
               },
               "tooltip" => %{"mode" => "multi"}
             }

      assert Enum.all?(
               ~w(yaxes yaxis xaxis legend tooltip lines fill points bars thresholds pluginVersion),
               &(not Map.has_key?(migrated, &1))
             )
    end

    test "points → showPoints always" do
      graph = %{"type" => "graph", "title" => "P", "points" => true, "targets" => []}
      [panel] = Dashboards.migrate_graph_panels(%{"panels" => [graph]})["panels"]

      assert get_in(panel, ["fieldConfig", "defaults", "custom", "showPoints"]) == "always"
    end

    test "bars → drawStyle bars, заливка ×10, повторный вызов ничего не меняет" do
      graph = %{"type" => "graph", "title" => "P", "bars" => true, "fill" => 2, "linewidth" => 1, "targets" => []}
      once = Dashboards.migrate_graph_panels(%{"panels" => [graph]})
      [panel] = Map.fetch!(once, "panels")
      custom = get_in(panel, ["fieldConfig", "defaults", "custom"])

      assert custom["drawStyle"] == "bars"
      assert custom["fillOpacity"] == 20
      assert Dashboards.migrate_graph_panels(once) == once
    end

    test "панели других типов не меняются, панели свёрнутого ряда мигрируют" do
      stat = %{"type" => "stat", "title" => "S", "targets" => []}

      row = %{
        "type" => "row",
        "title" => "R",
        "panels" => [%{"type" => "graph", "title" => "G", "yaxes" => [%{"format" => "s"}]}]
      }

      assert [stat, row] = Dashboards.migrate_graph_panels(%{"panels" => [stat, row]})["panels"]
      assert stat["type"] == "stat"
      assert [nested] = row["panels"]
      assert nested["type"] == "timeseries"
      assert nested["fieldConfig"]["defaults"]["unit"] == "s"
    end

    test "дашборд без панелей не меняется" do
      assert Dashboards.migrate_graph_panels(%{"title" => "t"}) == %{"title" => "t"}
    end
  end

  defp panel(dashboard, title), do: Enum.find(panels(dashboard), &(&1["title"] == title))

  defp panels(dashboard), do: Enum.flat_map(dashboard["panels"], &[&1 | Map.get(&1, "panels", [])])
end
