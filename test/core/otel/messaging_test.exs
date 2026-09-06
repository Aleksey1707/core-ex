defmodule Core.Otel.MessagingTest do
  # Экспортёр span'ов — глобальный ресурс SDK.
  use ExUnit.Case, async: false

  alias Core.Otel
  alias Core.OtelFixture

  setup do
    :ok = OtelFixture.attach()
    :ok
  end

  describe "create/4" do
    test "родитель — контекст из carrier, в carrier уходит контекст create-span'а" do
      command_headers = Otel.span("cmd", [], fn -> Otel.inject(%{"name" => "created"}) end)

      {headers, _span_ctx} = Otel.Messaging.create(command_headers, "products", "agg-1")

      spans = OtelFixture.drain()
      command = OtelFixture.find(spans, "cmd")
      create = OtelFixture.find(spans, "create products")

      assert create.kind == :producer
      assert create.trace_id == command.trace_id
      assert create.parent_span_id == command.span_id

      assert create.attributes["messaging.operation.type"] == "create"
      assert create.attributes["messaging.operation.name"] == "create"
      assert create.attributes["messaging.destination.name"] == "products"
      assert create.attributes["messaging.message.id"] == "agg-1"

      assert headers["name"] == "created"
      assert headers["traceparent"] != command_headers["traceparent"]
    end

    test "без message_id атрибут не ставится" do
      Otel.Messaging.create(%{}, "products", nil)

      create = OtelFixture.drain() |> OtelFixture.find("create products")

      refute Map.has_key?(create.attributes, "messaging.message.id")
    end

    test "system и собственные атрибуты" do
      opts = [system: "rabbitmq", attributes: %{"core.outbox.record" => "r-1"}]
      Otel.Messaging.create(%{}, "products", "agg-1", opts)

      create = OtelFixture.drain() |> OtelFixture.find("create products")

      assert create.attributes["messaging.system"] == "rabbitmq"
      assert create.attributes["core.outbox.record"] == "r-1"
    end
  end

  describe "send/5" do
    test "ссылается на контексты создания, а не вкладывает их" do
      {_headers, first} = Otel.Messaging.create(%{}, "products", "agg-1")
      {_headers, second} = Otel.Messaging.create(%{}, "products", "agg-2")

      creates = OtelFixture.drain()

      assert :ok = Otel.Messaging.send("products", 2, [first, second], [], fn -> :ok end)

      span = OtelFixture.drain() |> OtelFixture.find("send products")

      assert span.kind == :producer
      assert span.attributes["messaging.operation.type"] == "send"
      assert span.attributes["messaging.batch.message_count"] == 2
      assert span.parent_span_id == :undefined
      assert Enum.sort(span.links) == Enum.sort(Enum.map(creates, &OtelFixture.ref/1))
    end

    test "без общего назначения имя span'а — одна операция" do
      Otel.Messaging.send(nil, 2, [], [operation_name: "publish"], fn -> :ok end)

      span = OtelFixture.drain() |> OtelFixture.find("send")

      assert span.attributes["messaging.operation.name"] == "publish"
      refute Map.has_key?(span.attributes, "messaging.destination.name")
    end
  end

  describe "process/5" do
    test "родитель — creation context из заголовков сообщения" do
      {headers, _span_ctx} = Otel.Messaging.create(%{}, "products", "agg-1")
      create = OtelFixture.drain() |> OtelFixture.find("create products")

      opts = [attributes: %{"core.pubsub.attempt" => 2}]
      assert :ok = Otel.Messaging.process(headers, "products", "agg-1", opts, fn -> :ok end)

      span = OtelFixture.drain() |> OtelFixture.find("process products")

      assert span.kind == :consumer
      assert span.trace_id == create.trace_id
      assert span.parent_span_id == create.span_id
      assert span.attributes["messaging.operation.type"] == "process"
      assert span.attributes["messaging.message.id"] == "agg-1"
      assert span.attributes["core.pubsub.attempt"] == 2
    end
  end
end
