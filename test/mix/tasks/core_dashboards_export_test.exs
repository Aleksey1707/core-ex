defmodule Mix.Tasks.Core.Dashboards.ExportTest do
  # Задача пишет в каталог по умолчанию относительно текущего: тест меняет cwd процесса VM.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Core.PromEx.Dashboards
  alias Core.PromExFixture
  alias Mix.Tasks.Core.Dashboards.Export

  @moduletag :tmp_dir

  @default_out "deploy/monitoring/grafana/dashboards"

  test "без --dashboard — набор по умолчанию в каталог по умолчанию", %{tmp_dir: tmp_dir} do
    output = in_dir(tmp_dir, ["--module", "Core.PromExFixture.Outbox"])

    out = Path.join(tmp_dir, @default_out)
    assert File.ls!(out) |> Enum.sort() == ["beam.json", "outbox.json"]

    for name <- [:outbox, :beam] do
      assert File.read!(Path.join(out, "#{name}.json")) == Dashboards.render(PromExFixture.Outbox, name)
    end

    assert output =~ "#{@default_out}/outbox.json"
    assert output =~ "#{@default_out}/beam.json"
  end

  test "без плагинов подсистем и штатных PromEx набор по умолчанию пуст", %{tmp_dir: tmp_dir} do
    output = in_dir(tmp_dir, ["--module", "Core.PromExFixture.MqBare"])

    refute File.exists?(Path.join(tmp_dir, @default_out))
    assert output =~ "нет дашбордов"
  end

  test "--dashboard выбирает дашборд мимо набора по умолчанию", %{tmp_dir: tmp_dir} do
    in_dir(tmp_dir, ["--module", "Core.PromExFixture.Bare", "--dashboard", "outbox", "--dashboard", "outbox"])

    path = Path.join([tmp_dir, @default_out, "outbox.json"])
    assert File.read!(path) == Dashboards.render(PromExFixture.Bare, :outbox)
  end

  test "--dashboard выбирает штатный дашборд PromEx", %{tmp_dir: tmp_dir} do
    in_dir(tmp_dir, ["--module", "Core.PromExFixture.Bare", "--dashboard", "beam"])

    path = Path.join([tmp_dir, @default_out, "beam.json"])
    assert File.read!(path) == Dashboards.render(PromExFixture.Bare, :beam)
  end

  test "--out задаёт каталог выгрузки", %{tmp_dir: tmp_dir} do
    in_dir(tmp_dir, ["--module", "Core.PromExFixture.Outbox", "--out", "grafana/custom"])

    assert File.ls!(Path.join(tmp_dir, "grafana/custom")) |> Enum.sort() == ["beam.json", "outbox.json"]
    refute File.exists?(Path.join(tmp_dir, @default_out))
  end

  test "без --module — отказ" do
    assert_raise Mix.Error, ~r/укажите --module/, fn -> Export.run([]) end
  end

  test "неизвестный модуль — отказ" do
    assert_raise Mix.Error, ~r/--module Core.PromExFixture.Missing: модуль PromEx не найден/, fn ->
      Export.run(["--module", "Core.PromExFixture.Missing"])
    end

    assert_raise Mix.Error, ~r/--module Core.PromExFixture: модуль PromEx не найден/, fn ->
      Export.run(["--module", "Core.PromExFixture"])
    end
  end

  test "неизвестный дашборд — отказ с перечнем" do
    assert_raise Mix.Error, ~r/--dashboard nope: .*outbox/, fn ->
      Export.run(["--module", "Core.PromExFixture.Outbox", "--dashboard", "nope"])
    end
  end

  # ---

  defp in_dir(dir, argv), do: capture_io(fn -> File.cd!(dir, fn -> Export.run(argv) end) end)
end
