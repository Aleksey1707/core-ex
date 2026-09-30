defmodule Core.Mq.Kafka.ReaderKafkaTest do
  use Core.DataCase, async: false

  @moduletag :kafka

  import ExUnit.CaptureLog

  alias Core.Mq
  alias Core.Mq.Kafka.Reader
  alias Core.Mq.Kafka.Writer

  @endpoints [{~c"localhost", String.to_integer(System.get_env("KAFKA_PORT", "9093"))}]

  setup do
    client = :"kafka_reader_test_#{System.unique_integer([:positive])}"
    topic = "kafka_reader_test_#{System.unique_integer([:positive])}"

    :ok = create_topic(topic, 2)

    start_supervised!(%{
      id: client,
      start: {:brod, :start_link_client, [@endpoints, client, [auto_start_producers: true]]}
    })

    {:ok, client: client, topic: topic}
  end

  test "читает запись Kafka как есть и после рестарта продолжает с зафиксированного смещения", %{
    client: client,
    topic: topic
  } do
    key = Mq.Key.new!(<<0, 1, 0xFF>>)
    :ok = Writer.put_many(client, [message!(topic, "a", key, %{"Name" => "a"}), message!(topic, nil, key)])

    reader = start_supervised!({Reader, reader_opts(client, topic)})

    assert {:ok, first} = Reader.get(reader, 10_000)
    assert %Mq.Message{body: "a", key: ^key, headers: %{"name" => "a"}} = first
    assert %Mq.Position{partition: partition, offset: 0} = first.position
    assert :ok = Reader.commit(reader)

    assert {:ok, %Mq.Message{body: nil, position: %Mq.Position{partition: ^partition, offset: 1}}} =
             Reader.get(reader, 10_000)

    stop_supervised!(Reader)

    reader = start_supervised!({Reader, reader_opts(client, topic)})

    assert {:ok, %Mq.Message{body: nil, position: %Mq.Position{offset: 1}}} = Reader.get(reader, 10_000)
    assert :ok = Reader.commit(reader)
    assert :empty = Reader.get(reader, 500)
  end

  test "новые партиции топика читаются без рестарта", %{client: client, topic: topic} do
    reader = start_supervised!({Reader, reader_opts(client, topic, partitions_interval_ms: 200)})
    assert :empty = Reader.get(reader, 1_000)

    :ok =
      :brod.create_partitions(
        @endpoints,
        [%{topic: topic, new_partitions: %{count: 3, assignment: :undefined}}],
        %{timeout: 5_000}
      )

    :ok = await_leaders(topic, 3, 50)

    # Продюсеры `:brod` тоже заводятся на старте топика: новую партицию видит только новый клиент.
    producer = :"#{client}_producer"

    start_supervised!(%{
      id: producer,
      start: {:brod, :start_link_client, [@endpoints, producer, [auto_start_producers: true]]}
    })

    capture_log(fn ->
      :ok = :brod.produce_sync(producer, topic, 2, "k", "new")

      assert {:ok, %Mq.Message{body: "new", position: %Mq.Position{partition: 2}}} = Reader.get(reader, 15_000)
    end)
  end

  defp reader_opts(client, topic, opts \\ []) do
    Keyword.merge(
      [
        client: client,
        topic: Mq.Topic.new!(topic),
        subscriber_name: Mq.SubscriberName.new!("kafka_reader_test"),
        repo: TestRepo
      ],
      opts
    )
  end

  defp create_topic(topic, partitions) do
    config = %{name: topic, num_partitions: partitions, replication_factor: 1, assignments: [], configs: []}

    with :ok <- :brod.create_topics(@endpoints, [config], %{timeout: 5_000}),
         do: await_leaders(topic, partitions, 50)
  end

  # Сразу после создания у партиций ещё нет лидера: первая запись получила бы
  # `not_leader_for_partition` и повтор внутри клиента.
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

  defp message!(topic, body, key, headers \\ %{}) do
    {:ok, message} = Mq.Message.new(Mq.Topic.new!(topic), headers, body, key)

    message
  end
end
