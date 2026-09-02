defmodule Core.Cache.PromExTest do
  use ExUnit.Case, async: false

  alias Core.Cache
  alias Core.Cache.PromEx

  defmodule StubSizes do
    def empty, do: []

    def two do
      [%{cache: "stub_a", size: 3}, %{cache: "stub_b", size: 0}]
    end
  end

  test "event_metrics содержит cache.requests" do
    assert [%{metrics: metrics}] = List.wrap(PromEx.event_metrics(otp_app: :core))

    names = Enum.map(metrics, &Enum.join(&1.name, "."))

    assert Enum.any?(names, &String.contains?(&1, "cache.requests"))
  end

  test "polling_metrics содержит cache.size" do
    opts = [otp_app: :core, poll_rate: 5_000, sizes: {StubSizes, :empty, []}]

    assert [%{metrics: poll_metrics, poll_rate: 5_000}] = List.wrap(PromEx.polling_metrics(opts))

    names = Enum.map(poll_metrics, &Enum.join(&1.name, "."))

    assert Enum.any?(names, &String.contains?(&1, "cache.size"))
  end

  test "polling_metrics требует sizes:" do
    assert_raise KeyError, fn ->
      PromEx.polling_metrics(otp_app: :core, poll_rate: 5_000)
    end
  end

  test "execute_size_metrics эмитит гейдж на каждый кеш" do
    attach("cache-promex-size-#{inspect(self())}", [:prom_ex, :plugin, :cache, :size])

    PromEx.execute_size_metrics({StubSizes, :two, []})

    assert_receive {:telemetry, [:prom_ex, :plugin, :cache, :size], %{value: 3},
                    %{cache: "stub_a"}}

    assert_receive {:telemetry, [:prom_ex, :plugin, :cache, :size], %{value: 0},
                    %{cache: "stub_b"}}
  end

  test "emit_request эмитит событие обращения" do
    attach("cache-promex-request-#{inspect(self())}", Cache.Telemetry.request_event())

    Cache.Telemetry.emit_request("stub_a", :hit)

    assert_receive {:telemetry, _event, %{count: 1}, %{cache: "stub_a", result: :hit}}
  end

  defp attach(handler_id, event) do
    :ok =
      :telemetry.attach(
        handler_id,
        event,
        fn event, measurements, metadata, test_pid ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end
