defmodule Core.Cgroup.PromExTest do
  use ExUnit.Case, async: false

  alias Core.Cgroup.PromEx

  setup do
    path = Path.join(System.tmp_dir!(), "cgroup-promex-#{System.unique_integer([:positive])}")

    stat_path =
      Path.join(System.tmp_dir!(), "cgroup-promex-stat-#{System.unique_integer([:positive])}")

    File.write!(path, "999\n")
    File.write!(stat_path, "anon 100\nfile 800\ninactive_file 700\n")

    on_exit(fn ->
      File.rm(path)
      File.rm(stat_path)
    end)

    {:ok, memory_opts: [current_path: path, stat_path: stat_path]}
  end

  test "polling_metrics содержит gauge'и cgroup memory", %{memory_opts: memory_opts} do
    opts = [otp_app: :core, poll_rate: 5_000] ++ memory_opts

    assert [%{metrics: poll_metrics, poll_rate: 5_000}] =
             List.wrap(PromEx.polling_metrics(opts))

    names =
      poll_metrics
      |> Enum.map(&Enum.join(&1.name, "."))

    for suffix <- ~w(current anon max) do
      assert Enum.any?(names, &String.contains?(&1, "cgroup.memory.#{suffix}"))
    end
  end

  test "execute_memory_metrics эмитит bytes", %{memory_opts: memory_opts} do
    handler_id = "cgroup-promex-#{inspect(self())}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:prom_ex, :plugin, :cgroup, :memory],
        fn event, measurements, metadata, test_pid ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    PromEx.execute_memory_metrics(memory_opts)

    assert_receive {:telemetry, [:prom_ex, :plugin, :cgroup, :memory], %{bytes: 999}, %{}}
  end

  test "execute_memory_metrics эмитит anon", %{memory_opts: memory_opts} do
    handler_id = "cgroup-promex-anon-#{inspect(self())}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:prom_ex, :plugin, :cgroup, :memory_anon],
        fn event, measurements, metadata, test_pid ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    PromEx.execute_memory_metrics(memory_opts)

    assert_receive {:telemetry, [:prom_ex, :plugin, :cgroup, :memory_anon], %{bytes: 100}, %{}}
  end

  test "execute_memory_metrics no-op при :unavailable" do
    missing = [current_path: "/tmp/missing-cgroup-#{System.unique_integer([:positive])}"]

    handler_id = "cgroup-promex-miss-#{inspect(self())}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:prom_ex, :plugin, :cgroup, :memory],
        fn event, measurements, metadata, test_pid ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert :ok = PromEx.execute_memory_metrics(missing)
    refute_received {:telemetry, [:prom_ex, :plugin, :cgroup, :memory], _, _}
  end
end
