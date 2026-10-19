defmodule Core.External.PromExTest do
  use ExUnit.Case, async: true

  alias Core.External.PromEx

  test "гистограмма длительности и счётчик вызовов по system, operation и outcome" do
    assert [%{metrics: metrics}] = PromEx.event_metrics(otp_app: :my_app)
    by_name = Map.new(metrics, &{&1.name, &1})
    tags = [:system, :operation, :outcome]

    assert %Telemetry.Metrics.Distribution{tags: ^tags, unit: :millisecond} =
             duration = Map.fetch!(by_name, [:my_app, :prom_ex, :external, :call, :duration, :milliseconds])

    assert %Telemetry.Metrics.Counter{tags: ^tags} =
             total = Map.fetch!(by_name, [:my_app, :prom_ex, :external, :call, :total])

    stop = Core.Telemetry.event([:external, :call, :stop])
    assert duration.event_name == stop
    assert total.event_name == stop

    assert total.tag_values.(%{system: :sms, operation: :send, outcome: :timeout}) == %{
             system: "sms",
             operation: "send",
             outcome: "timeout"
           }
  end
end
