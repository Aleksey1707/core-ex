defmodule Core.Mq.PromExTest do
  use ExUnit.Case, async: false

  alias Core.Mq.PromEx

  test "event_metrics и polling_metrics непусты" do
    opts = [otp_app: :core, poll_rate: 5_000]

    assert [%{metrics: event_metrics}] = List.wrap(PromEx.event_metrics(opts))
    assert event_metrics != []

    names =
      event_metrics
      |> Enum.map(&Enum.join(&1.name, "."))

    assert Enum.any?(names, &String.contains?(&1, "mq.publish"))
    assert Enum.any?(names, &String.contains?(&1, "mq.deliver.entries"))
    assert Enum.any?(names, &String.contains?(&1, "mq.decode_drop"))
    assert Enum.any?(names, &String.contains?(&1, "mq.subscriber.cycles"))

    assert [%{metrics: poll_metrics, poll_rate: 5_000}] =
             List.wrap(PromEx.polling_metrics(opts))

    poll_names =
      poll_metrics
      |> Enum.map(&Enum.join(&1.name, "."))

    assert Enum.any?(poll_names, &String.contains?(&1, "mq.reader.buffer_len"))
    assert Enum.any?(poll_names, &String.contains?(&1, "mq.reader.pending"))
  end

  test "execute_reader_metrics no-op без живого reader" do
    handler_id = "mq-promex-#{inspect(self())}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:prom_ex, :plugin, :mq, :reader, :buffer_len],
        fn event, measurements, metadata, test_pid ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert :ok = PromEx.execute_reader_metrics([])
    refute_received {:telemetry, [:prom_ex, :plugin, :mq, :reader, :buffer_len], _, _}
  end
end
