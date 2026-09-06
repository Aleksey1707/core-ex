defmodule Core.OtelChainTest do
  # Экспортёр span'ов — глобальный ресурс SDK.
  use ExUnit.Case, async: false

  alias Core.Context
  alias Core.EventFixture
  alias Core.MqFake
  alias Core.Otel
  alias Core.OtelFixture
  alias Core.Outbox
  alias Core.PubSub.MqSubscriberReliable

  defmodule Fixture do
    @moduledoc false

    use Core.Es.Outbox,
      topic: "fakes",
      event: Core.EventFixture.Event
  end

  setup do
    :ok = OtelFixture.attach()
    :ok
  end

  test "трейс команды доходит до обработчика: Es.Outbox → Delivery → подписчик" do
    writer = MqFake.Writer.new()
    delivery = Outbox.Delivery.Mq.new(MqFake.Writer, writer)

    {:ok, record} = Otel.span("cmd", [], fn -> Fixture.from_event(EventFixture.created()) end)

    assert :ok = Outbox.Delivery.Mq.publish_many(delivery, [record])
    assert [published] = MqFake.Writer.published(writer)

    subscriber = start_sub(MqFake.QueueReader.new([published]))

    assert :ok = MqSubscriberReliable.subscribe(subscriber, nil, Context.new())
    assert :processed = MqSubscriberReliable.run_once(subscriber)

    spans = OtelFixture.drain()
    command = OtelFixture.find(spans, "cmd")
    create = OtelFixture.find(spans, "create fakes")
    send_span = OtelFixture.find(spans, "send fakes")
    process = OtelFixture.find(spans, "process fakes")

    assert create.trace_id == command.trace_id
    assert process.trace_id == command.trace_id

    assert create.parent_span_id == command.span_id
    assert process.parent_span_id == create.span_id
    assert send_span.links == [OtelFixture.ref(create)]
  end

  # ---

  defp start_sub(reader) do
    child_opts = [
      reader_module: MqFake.QueueReader,
      reader: reader,
      from_message: fn message -> {:ok, message} end,
      on_message: fn _message, _data, _context -> :ok end,
      topic: "fakes",
      poll_interval_ms: 60_000
    ]

    {:ok, subscriber} = start_supervised({MqSubscriberReliable, child_opts})

    subscriber
  end
end
