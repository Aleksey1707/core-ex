defmodule Core.Outbox.PromExTest do
  use Core.DataCase, async: false

  import ExUnit.CaptureLog

  alias Core.Outbox.PromEx

  defmodule DownRepo do
    @moduledoc false

    def counts_by_status, do: exit({:noproc, {DBConnection, :checkout, []}})
  end

  test "event_metrics и polling_metrics непусты" do
    opts = [otp_app: :core, poll_rate: 5_000]

    assert [%{metrics: event_metrics}] = List.wrap(PromEx.event_metrics(opts))
    assert event_metrics != []

    names =
      event_metrics
      |> Enum.map(&Enum.join(&1.name, "."))

    assert Enum.any?(names, &String.contains?(&1, "outbox.poller.cycles"))
    assert Enum.any?(names, &String.contains?(&1, "outbox.poller.published"))
    assert Enum.any?(names, &String.contains?(&1, "outbox.poller.retry"))
    assert Enum.any?(names, &String.contains?(&1, "outbox.poller.failed"))
    assert Enum.any?(names, &String.contains?(&1, "outbox.delivery"))
    assert Enum.any?(names, &String.contains?(&1, "outbox.cleaner"))

    assert [%{metrics: poll_metrics, poll_rate: 5_000}] =
             List.wrap(PromEx.polling_metrics(opts))

    assert length(poll_metrics) == 3
  end

  test "недоступный источник не роняет провайдер, метрика не эмитится" do
    handler_id = "outbox-promex-down-#{inspect(self())}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:prom_ex, :plugin, :outbox, :queue, :count],
        fn event, measurements, metadata, test_pid ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        self()
      )

    configured = Application.fetch_env!(:core, Core.Outbox.Repo)

    on_exit(fn ->
      :telemetry.detach(handler_id)
      Application.put_env(:core, Core.Outbox.Repo, configured)
    end)

    Application.put_env(:core, Core.Outbox.Repo, DownRepo)

    log = capture_log(fn -> assert :ok = PromEx.execute_queue_metrics() end)

    assert log =~ "сбор метрик пропущен"
    refute_received {:telemetry, [:prom_ex, :plugin, :outbox, :queue, :count], _, _}
  end

  test "execute_queue_metrics эмитит gauges" do
    handler_id = "outbox-promex-#{inspect(self())}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:prom_ex, :plugin, :outbox, :queue, :count],
          [:prom_ex, :plugin, :outbox, :queue, :oldest_age],
          [:prom_ex, :plugin, :outbox, :queue, :expired_locks]
        ],
        fn event, measurements, metadata, test_pid ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    PromEx.execute_queue_metrics()

    assert_receive {:telemetry, [:prom_ex, :plugin, :outbox, :queue, :count], %{count: _},
                    %{status: "new"}}

    assert_receive {:telemetry, [:prom_ex, :plugin, :outbox, :queue, :oldest_age],
                    %{seconds: seconds}, %{}}

    assert seconds >= 0

    assert_receive {:telemetry, [:prom_ex, :plugin, :outbox, :queue, :expired_locks], %{count: _},
                    %{}}
  end
end
