defmodule Core.TelemetryTest do
  use ExUnit.Case, async: true

  alias Core.Telemetry

  test "event/1 добавляет префикс приложения" do
    assert Telemetry.event([:outbox, :poller]) == [:core, :outbox, :poller]
  end

  test "span/3 эмитит start и stop с префиксом" do
    handler_id = "telemetry-span-#{inspect(self())}"
    parent = self()

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:core, :work, :start],
          [:core, :work, :stop]
        ],
        fn event, _measurements, metadata, _config -> send(parent, {:span, event, metadata}) end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert :done = Telemetry.span([:work], %{kind: :test}, fn -> {:done, %{kind: :test}} end)

    assert_received {:span, [:core, :work, :start], %{kind: :test}}
    assert_received {:span, [:core, :work, :stop], %{kind: :test}}
  end
end
