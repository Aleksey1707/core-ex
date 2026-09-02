defmodule Core.Mq.StreamTest do
  use ExUnit.Case, async: false

  @moduletag :rabbit_stream

  alias Core.Mq
  alias Core.Mq.Message
  alias Core.Mq.Stream.Connection
  alias Core.Mq.Stream.Reader
  alias Core.Mq.Stream.Writer

  setup do
    :ok = Connection.connect()

    topic = Mq.Topic.new!("mq_stream_test_#{System.unique_integer([:positive])}")

    {:ok, writer} =
      start_supervised({Writer, connection: Connection, reference_prefix: "test-writer"})

    {:ok, writer: writer, topic: topic}
  end

  test "publish и два reliable subscriber читают независимо", %{writer: writer, topic: topic} do
    assert {:ok, msg} =
             Message.new(
               topic,
               %{"name" => "created"},
               "hello",
               Mq.Key.new!("agg-1")
             )

    assert :ok = Writer.put(writer, msg)

    {:ok, a} =
      Reader.start_link(
        connection: Connection,
        topic: topic,
        subscriber_name: Mq.SubscriberName.new!("sub_a"),
        reliable?: true,
        initial_offset: :first
      )

    {:ok, b} =
      Reader.start_link(
        connection: Connection,
        topic: topic,
        subscriber_name: Mq.SubscriberName.new!("sub_b"),
        reliable?: true,
        initial_offset: :first
      )

    assert {:ok, %Message{body: "hello"}} = Reader.get(a, 2_000)
    assert {:ok, %Message{body: "hello"}} = Reader.get(b, 2_000)
    assert :ok = Reader.commit(a)
    assert :ok = Reader.commit(b)

    GenServer.stop(a)
    GenServer.stop(b)
  end

  test "credit по чанкам: put_many читается целиком без роста buffer на каждый pop", %{
    writer: writer,
    topic: topic
  } do
    messages =
      Enum.map(1..100, fn i ->
        {:ok, msg} = Message.new(topic, %{"name" => "n"}, "body-#{i}", Mq.Key.new!("agg-1"))
        msg
      end)

    assert :ok = Writer.put_many(writer, messages)

    {:ok, reader} =
      Reader.start_link(
        connection: Connection,
        topic: topic,
        subscriber_name: Mq.SubscriberName.new!("sub_credit"),
        reliable?: true,
        credit: 2,
        initial_offset: :first
      )

    Process.sleep(500)
    initial = Reader.info(reader).buffer_len
    assert initial > 0
    assert initial <= 100

    max_len =
      Enum.reduce(1..100, initial, fn _, acc ->
        assert {:ok, %Message{}} = Reader.get(reader, 2_000)
        assert :ok = Reader.commit(reader)
        max(acc, Reader.info(reader).buffer_len)
      end)

    assert :empty = Reader.get(reader, 200)
    assert max_len <= 100
    GenServer.stop(reader)
  end
end
