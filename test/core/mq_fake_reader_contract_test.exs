defmodule Core.MqFake.QueueReaderContractTest do
  use ExUnit.Case, async: true
  use Core.MqReaderContract, impl: Core.MqFake.QueueReader

  alias Core.Mq
  alias Core.Mq.Message
  alias Core.MqFake

  @topic Mq.Topic.new!("contract")

  def start_reader(_context), do: MqFake.QueueReader.new()

  def publish(reader, body) do
    {:ok, message} = Message.new(@topic, %{}, body, nil)
    MqFake.QueueReader.push(reader, message)
  end
end

defmodule Core.MqFake.ReadyQueueReaderContractTest do
  use ExUnit.Case, async: true
  use Core.MqReaderContract, impl: Core.MqFake.ReadyQueueReader

  alias Core.Mq
  alias Core.Mq.Message
  alias Core.MqFake

  @topic Mq.Topic.new!("contract")

  def start_reader(_context) do
    name = :"ready_contract_#{System.unique_integer([:positive])}"
    start_supervised!({MqFake.ReadyQueueReader, name: name})
    name
  end

  def publish(reader, body) do
    {:ok, message} = Message.new(@topic, %{}, body, nil)
    MqFake.ReadyQueueReader.push(reader, message)
  end
end
