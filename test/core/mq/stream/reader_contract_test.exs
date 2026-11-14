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
    reader =
      start_supervised!(
        {Core.Mq.Stream.Reader,
         connection: Connection,
         topic: context.topic,
         subscriber_name: Mq.SubscriberName.new!("reader-contract-#{System.unique_integer([:positive])}"),
         reliable?: true,
         initial_offset: :first}
      )

    sink = {context.writer, context.topic}
    Process.put(:reader_contract_sinks, Map.put(Process.get(:reader_contract_sinks, %{}), reader, sink))
    reader
  end

  def publish(reader, body) do
    {writer, topic} = Process.get(:reader_contract_sinks) |> Map.fetch!(reader)
    {:ok, message} = Message.new(topic, %{}, body, nil)
    Writer.put(writer, message)
  end
end
