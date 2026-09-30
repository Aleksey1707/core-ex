defmodule Core.Mq.Kafka.WriterKafkaTest do
  use ExUnit.Case, async: false

  @moduletag :kafka

  alias Core.Error
  alias Core.Mq
  alias Core.Mq.Kafka.Writer

  require Record

  Record.defrecordp(:kafka_message, Record.extract(:kafka_message, from_lib: "kafka_protocol/include/kpro_public.hrl"))

  @endpoints [{~c"localhost", String.to_integer(System.get_env("KAFKA_PORT", "9093"))}]
  @partitions 7

  setup do
    client = :"kafka_writer_test_#{System.unique_integer([:positive])}"
    topic = "kafka_writer_test_#{System.unique_integer([:positive])}"

    :ok = create_topic(topic)

    start_supervised!(%{
      id: client,
      start: {:brod, :start_link_client, [@endpoints, client, [auto_start_producers: true]]}
    })

    {:ok, client: client, topic: topic}
  end

  test "ключ → партиция murmur2, как у DefaultPartitioner Kafka", %{client: client, topic: topic} do
    messages = for key <- ~w(foobar 21 abc), do: message!(topic, key, Mq.Key.new!(key))

    assert :ok = Writer.put_many(client, messages)

    assert values_by_partition(topic) == %{0 => ["foobar"], 3 => ["21"], 4 => ["abc"]}
  end

  test "пачка по одному ключу — в партиции по порядку, с ключом и заголовками", %{client: client, topic: topic} do
    key = Mq.Key.new!("foobar")
    messages = for body <- ~w(a b c), do: message!(topic, body, key, %{"name" => body})

    assert :ok = Writer.put_many(client, messages)

    assert [
             kafka_message(key: "foobar", value: "a", headers: [{"name", "a"}]),
             kafka_message(value: "b"),
             kafka_message(value: "c")
           ] = fetch(topic, 0)
  end

  test "неизвестный топик — ошибка, а не падение", %{client: client} do
    message = message!("kafka_writer_test_missing", "a", nil)

    assert {:error, %Error{code: :kafka_publish_failed, detail: :unknown_topic_or_partition}} =
             Writer.put(client, message)
  end

  defp create_topic(topic) do
    config = %{name: topic, num_partitions: @partitions, replication_factor: 1, assignments: [], configs: []}

    with :ok <- :brod.create_topics(@endpoints, [config], %{timeout: 5_000}),
         do: await_leaders(topic, 50)
  end

  # Сразу после создания у партиций ещё нет лидера: первая запись получила бы
  # `not_leader_for_partition` и повтор внутри клиента.
  defp await_leaders(topic, attempts) do
    leaders? = Enum.all?(0..(@partitions - 1), &match?({:ok, _}, :brod.resolve_offset(@endpoints, topic, &1)))

    cond do
      leaders? ->
        :ok

      attempts > 0 ->
        Process.sleep(100)
        await_leaders(topic, attempts - 1)

      true ->
        {:error, :no_leaders}
    end
  end

  defp values_by_partition(topic) do
    for partition <- 0..(@partitions - 1),
        values = Enum.map(fetch(topic, partition), &kafka_message(&1, :value)),
        values != [],
        into: %{},
        do: {partition, values}
  end

  defp fetch(topic, partition) do
    {:ok, {_high_watermark, messages}} = :brod.fetch(@endpoints, topic, partition, 0)
    messages
  end

  defp message!(topic, body, key, headers \\ %{}) do
    {:ok, message} = Mq.Message.new(Mq.Topic.new!(topic), headers, body, key)

    message
  end
end
