defmodule Core.Mq.Stream.ReaderContractTest do
  use ExUnit.Case, async: false
  use Core.MqReaderContract, impl: Core.Mq.Stream.Reader

  @moduletag :rabbit_stream

  alias Core.Mq
  alias Core.Mq.Message
  alias Core.Mq.Stream.Connection
  alias Core.Mq.Stream.Writer

  setup do
    :ok = Connection.connect()

    topic = Mq.Topic.new!("reader_contract_#{System.unique_integer([:positive])}")

    {:ok, writer} =
      start_supervised({Writer, connection: Connection, reference_prefix: "reader-contract"})

    {:ok, writer: writer, topic: topic}
  end

  def start_reader(context) do
    Process.put(:reader_contract_writer, context.writer)
    Process.put(:reader_contract_topic, context.topic)

    start_supervised!(
      {Core.Mq.Stream.Reader,
       connection: Connection,
       topic: context.topic,
       subscriber_name: Mq.SubscriberName.new!("reader-contract-#{System.unique_integer([:positive])}"),
       reliable?: true,
       initial_offset: :first}
    )
  end

  def publish(_reader, body) do
    {:ok, message} = Message.new(Process.get(:reader_contract_topic), %{}, body, nil)
    Writer.put(Process.get(:reader_contract_writer), message)
  end
end
