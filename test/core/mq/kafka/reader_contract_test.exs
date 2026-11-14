defmodule Core.Mq.Kafka.ReaderContractTest do
  use Core.DataCase, async: false
  use Core.MqReaderContract, impl: Core.Mq.Kafka.Reader

  @moduletag :kafka

  alias Core.Mq
  alias Core.Mq.Kafka.Writer
  alias Core.Mq.Message

  @endpoints [{~c"localhost", String.to_integer(System.get_env("KAFKA_PORT", "9093"))}]

  setup do
    client = :"kafka_reader_contract_#{System.unique_integer([:positive])}"
    topic = "kafka_reader_contract_#{System.unique_integer([:positive])}"

    :ok = create_topic(topic, 1)

    start_supervised!(%{
      id: client,
      start: {:brod, :start_link_client, [@endpoints, client, [auto_start_producers: true]]}
    })

    {:ok, client: client, topic: topic}
  end

  def start_reader(context) do
    Process.put(:reader_contract_client, context.client)
    Process.put(:reader_contract_topic, context.topic)

    start_supervised!(
      {Core.Mq.Kafka.Reader,
       client: context.client,
       topic: Mq.Topic.new!(context.topic),
       subscriber_name: Mq.SubscriberName.new!("kafka_reader_contract"),
       repo: TestRepo}
    )
  end

  def publish(_reader, body) do
    {:ok, message} = Message.new(Mq.Topic.new!(Process.get(:reader_contract_topic)), %{}, body, nil)
    Writer.put_many(Process.get(:reader_contract_client), [message])
  end

  defp create_topic(topic, partitions) do
    config = %{name: topic, num_partitions: partitions, replication_factor: 1, assignments: [], configs: []}

    with :ok <- :brod.create_topics(@endpoints, [config], %{timeout: 5_000}),
         do: await_leaders(topic, partitions, 50)
  end

  defp await_leaders(topic, partitions, attempts) do
    leaders? = Enum.all?(0..(partitions - 1), &match?({:ok, _}, :brod.resolve_offset(@endpoints, topic, &1)))

    cond do
      leaders? ->
        :ok

      attempts > 0 ->
        Process.sleep(100)
        await_leaders(topic, partitions, attempts - 1)

      true ->
        {:error, :no_leaders}
    end
  end
end
