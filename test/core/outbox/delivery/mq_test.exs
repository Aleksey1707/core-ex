defmodule Core.Outbox.Delivery.MqTest do
  # Экспортёр span'ов — глобальный ресурс SDK.
  use ExUnit.Case, async: false

  alias Core.Error
  alias Core.Mq
  alias Core.Otel
  alias Core.OtelFixture
  alias Core.Outbox
  alias Core.Outbox.Delivery
  alias Core.Outbox.Record

  setup do
    :ok = OtelFixture.attach()
    :ok
  end

  defmodule StopWriter do
    @moduledoc false

    alias Core.Error
    require Error

    def put_many(_writer, messages) do
      case messages do
        [_] ->
          :ok

        [_, _ | _] ->
          {:error, 1, Error.app(__MODULE__, code: :boom, ns: :outbox, message: "second")}
      end
    end
  end

  test "to_message: topic/key/body JSON" do
    {:ok, record} =
      Record.new(
        Outbox.Topic.new!("products"),
        Outbox.Key.new!("agg-1"),
        Outbox.Name.new!("created"),
        %{"event_id" => "e1", "x" => 1}
      )

    assert {:ok, message} = Delivery.Mq.to_message(record)
    assert Mq.Topic.value(message.topic) == "products"
    assert Mq.Key.value(message.key) == "agg-1"
    assert message.body == Jason.encode!(%{"event_id" => "e1", "x" => 1})
  end

  test "headers записи пробрасываются как есть" do
    {:ok, record} =
      Record.new(
        Outbox.Topic.new!("products"),
        Outbox.Key.new!("agg-1"),
        Outbox.Name.new!("created"),
        %{"event_id" => "e1"},
        %{"owner_id" => "o-1", "message_id" => "m-1"}
      )

    assert {:ok, message} = Delivery.Mq.to_message(record)
    assert message.headers == %{"owner_id" => "o-1", "message_id" => "m-1"}
  end

  test "headers nil → сообщение без заголовков" do
    {:ok, record} =
      Record.new(
        Outbox.Topic.new!("products"),
        Outbox.Key.new!("agg-1"),
        Outbox.Name.new!("created"),
        %{"event_id" => "e1"}
      )

    assert {:ok, message} = Delivery.Mq.to_message(record)
    assert message.headers == %{}
    assert Mq.Message.find_header(message, Mq.HeaderKey.new!("name")) == nil
    assert Mq.Message.find_header(message, Mq.HeaderKey.new!("aggr_id")) == nil
    assert Mq.Message.find_header(message, Mq.HeaderKey.new!("event_id")) == nil
  end

  defmodule RecordingWriter do
    @moduledoc false

    def put_many(agent, messages) do
      Agent.update(agent, fn calls -> calls ++ [messages] end)
      :ok
    end

    def calls(agent),
      do: Enum.map(Agent.get(agent, & &1), fn call -> Enum.map(call, & &1.body) end)

    def messages(agent), do: List.flatten(Agent.get(agent, & &1))
  end

  defmodule FailingWriter do
    @moduledoc false

    alias Core.Error
    require Error

    def put_many(agent, messages) do
      Agent.update(agent, fn calls -> calls ++ [Enum.map(messages, & &1.body)] end)
      {:error, 0, Error.app(__MODULE__, code: :boom, ns: :outbox, message: "writer")}
    end
  end

  test "publish_many: стоп на первой ошибке writer" do
    records =
      for name <- ~w(a b c) do
        {:ok, record} =
          Record.new(
            Outbox.Topic.new!("products"),
            Outbox.Key.new!("agg-1"),
            Outbox.Name.new!(name),
            %{"n" => name}
          )

        record
      end

    delivery = Delivery.Mq.new(StopWriter, :unused)
    assert {:error, 1, %Error{message: "second"}} = Delivery.Mq.publish_many(delivery, records)
  end

  test "publish_many: ошибка encode в середине — префикс реально опубликован" do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    records = [record("a"), broken_record("b"), record("c")]
    delivery = Delivery.Mq.new(RecordingWriter, agent)

    assert {:error, 1, %Error{code: :encode_payload_failed}} =
             Delivery.Mq.publish_many(delivery, records)

    assert [[body]] = RecordingWriter.calls(agent)
    assert body == Jason.encode!(%{"n" => "a"})
  end

  test "publish_many: ошибка encode в первой записи — writer не вызывается" do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    delivery = Delivery.Mq.new(RecordingWriter, agent)

    assert {:error, 0, %Error{code: :encode_payload_failed}} =
             Delivery.Mq.publish_many(delivery, [broken_record("a"), record("b")])

    assert RecordingWriter.calls(agent) == []
  end

  test "publish_many: провал публикации префикса важнее ошибки encode" do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    records = [record("a"), broken_record("b")]
    delivery = Delivery.Mq.new(FailingWriter, agent)

    assert {:error, 0, %Error{code: :boom}} = Delivery.Mq.publish_many(delivery, records)
  end

  describe "трассировка" do
    test "заголовки сообщения несут контекст create-span'а с родителем из записи" do
      command_headers = Otel.span("cmd", [], fn -> Otel.inject(%{"name" => "created"}) end)
      {:ok, agent} = Agent.start_link(fn -> [] end)
      delivery = Delivery.Mq.new(RecordingWriter, agent)

      assert :ok = Delivery.Mq.publish_many(delivery, [record("a", command_headers)])

      spans = OtelFixture.drain()
      command = OtelFixture.find(spans, "cmd")
      create = OtelFixture.find(spans, "create products")

      assert create.kind == :producer
      assert create.trace_id == command.trace_id
      assert create.parent_span_id == command.span_id
      assert create.attributes["messaging.operation.type"] == "create"
      assert create.attributes["messaging.destination.name"] == "products"
      assert create.attributes["messaging.message.id"] == "agg-1"

      assert [%{headers: headers}] = RecordingWriter.messages(agent)
      assert headers["name"] == "created"
      assert headers["traceparent"] != command_headers["traceparent"]
      assert headers["traceparent"] =~ hex_span_id(create.span_id)
    end

    test "пачка даёт один send-span со ссылками на create-спаны" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      delivery = Delivery.Mq.new(RecordingWriter, agent)

      assert :ok = Delivery.Mq.publish_many(delivery, [record("a"), record("b")])

      spans = OtelFixture.drain()
      send_span = OtelFixture.find(spans, "send products")
      creates = Enum.filter(spans, &(&1.name == "create products"))

      assert send_span.kind == :producer
      assert send_span.attributes["messaging.operation.type"] == "send"
      assert send_span.attributes["messaging.operation.name"] == "publish"
      assert send_span.attributes["messaging.batch.message_count"] == 2

      assert length(creates) == 2
      assert Enum.sort(send_span.links) == Enum.sort(Enum.map(creates, &OtelFixture.ref/1))
      assert Enum.all?(creates, &(&1.parent_span_id != send_span.span_id))
    end

    test "пачка из разных топиков — span без назначения в имени" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      delivery = Delivery.Mq.new(RecordingWriter, agent)

      records = [record("a"), %{record("b") | topic: Outbox.Topic.new!("orders")}]
      assert :ok = Delivery.Mq.publish_many(delivery, records)

      send_span = OtelFixture.drain() |> OtelFixture.find("send")

      assert send_span.attributes["messaging.batch.message_count"] == 2
      refute Map.has_key?(send_span.attributes, "messaging.destination.name")
    end

    test "провал публикации отмечается на send-span'е" do
      delivery = Delivery.Mq.new(StopWriter, :unused)

      assert {:error, 1, %Error{}} =
               Delivery.Mq.publish_many(delivery, [record("a"), record("b")])

      send_span = OtelFixture.drain() |> OtelFixture.find("send products")

      assert {:error, "second"} = send_span.status
      assert send_span.attributes["error.type"] == "outbox/boom"
    end
  end

  # ---

  defp hex_span_id(span_id) do
    span_id
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(16, "0")
  end

  defp record(name, headers \\ nil) do
    {:ok, record} =
      Record.new(
        Outbox.Topic.new!("products"),
        Outbox.Key.new!("agg-1"),
        Outbox.Name.new!(name),
        %{"n" => name},
        headers
      )

    record
  end

  defp broken_record(name) do
    %{record(name) | payload: %{"n" => {:not, :encodable}}}
  end
end
