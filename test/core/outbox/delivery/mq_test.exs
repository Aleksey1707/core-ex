defmodule Core.Outbox.Delivery.MqTest do
  use ExUnit.Case, async: true

  alias Core.Error
  alias Core.Mq
  alias Core.Outbox
  alias Core.Outbox.Delivery
  alias Core.Outbox.Record

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
      Agent.update(agent, fn calls -> calls ++ [Enum.map(messages, & &1.body)] end)
      :ok
    end

    def calls(agent), do: Agent.get(agent, & &1)
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

  # ---

  defp record(name) do
    {:ok, record} =
      Record.new(
        Outbox.Topic.new!("products"),
        Outbox.Key.new!("agg-1"),
        Outbox.Name.new!(name),
        %{"n" => name}
      )

    record
  end

  defp broken_record(name) do
    %{record(name) | payload: %{"n" => {:not, :encodable}}}
  end
end
