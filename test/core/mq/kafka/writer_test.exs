defmodule Core.Mq.Kafka.WriterTest do
  use ExUnit.Case, async: true

  alias Core.Error
  alias Core.KafkaFake
  alias Core.Mq
  alias Core.Mq.Kafka.Writer

  setup do
    client = :"kafka_fake_#{System.unique_integer([:positive])}"
    start_supervised!({KafkaFake, client: client, topics: %{"topic_a" => 7}})

    {:ok, client: client}
  end

  test "put: topic/key/value/headers → запись брокера", %{client: client} do
    assert :ok = Writer.put(client, message!(%{"owner_id" => "o-1"}, "body"))

    assert [%{topic: "topic_a", key: "owner-1", value: "body", headers: [{"owner_id", "o-1"}]}] =
             KafkaFake.published(client)
  end

  test "put: сообщение без заголовков", %{client: client} do
    assert :ok = Writer.put(client, message!(%{}, "body"))
    assert [%{headers: []}] = KafkaFake.published(client)
  end

  test "ключ → партиция murmur2, как у DefaultPartitioner Kafka", %{client: client} do
    messages = for key <- ~w(foobar 21 abc), do: message!(%{}, key, Mq.Key.new!(key))

    assert :ok = Writer.put_many(client, messages)
    assert Enum.map(KafkaFake.published(client), &{&1.key, &1.partition}) == [{"foobar", 0}, {"21", 3}, {"abc", 4}]
  end

  test "без ключа — пустой ключ на проводе и партиция из числа партиций топика", %{client: client} do
    assert :ok = Writer.put(client, message!(%{}, "body", nil))
    assert [%{key: "", partition: partition}] = KafkaFake.published(client)
    assert partition in 0..6
  end

  test "put_many: успех по порядку", %{client: client} do
    messages = for name <- ~w(a b c), do: message!(%{"name" => name}, name)

    assert :ok = Writer.put_many(client, messages)
    assert Enum.map(KafkaFake.published(client), & &1.value) == ~w(a b c)
  end

  for exit <- ~w(not_retriable reached_max_retries)a do
    test "put_many: стоп на первой ошибке брокера (#{exit})" do
      client = :"kafka_fake_#{System.unique_integer([:positive])}"

      start_supervised!({KafkaFake, client: client, topics: %{"topic_a" => 1}, fail_at: 1, exit: unquote(exit)})

      messages = for body <- ~w(ok-body fail tail), do: message!(%{}, body)

      assert {:error, 1, %Error{code: :kafka_publish_failed, detail: {:error_code, :message_too_large}}} =
               Writer.put_many(client, messages)

      assert Enum.map(KafkaFake.published(client), & &1.value) == ["ok-body"]
    end
  end

  test "неизвестный топик — ошибка без автосоздания, а не падение", %{client: client} do
    {:ok, message} = Mq.Message.new(Mq.Topic.new!("missing"), %{}, "body", nil)

    assert {:error, %Error{code: :kafka_publish_failed, detail: :unknown_topic_or_partition}} =
             Writer.put(client, message)
  end

  test "клиент не запущен — :client_down" do
    assert {:error, %Error{code: :kafka_publish_failed, detail: :client_down}} =
             Writer.put(:kafka_fake_not_started, message!(%{}, "body"))
  end

  test "пустое тело — отказ до отправки: на проводе оно стало бы tombstone", %{client: client} do
    assert {:error, 1, %Error{code: :kafka_publish_failed, detail: :empty_body}} =
             Writer.put_many(client, [message!(%{}, "a"), message!(%{}, ""), message!(%{}, "c")])

    assert Enum.map(KafkaFake.published(client), & &1.value) == ["a"]
  end

  test "nil-тело — tombstone: пустое значение на проводе", %{client: client} do
    assert :ok = Writer.put(client, message!(%{}, nil))
    assert [%{key: "owner-1", value: ""}] = KafkaFake.published(client)
  end

  test "любое исключение клиента становится ошибкой, а не падением вызывающего", %{client: client} do
    # Строка кеша метаданных, которую `:brod` не разбирает, — исключение в процессе вызывающего.
    :ets.insert(client, {{:topics, "topic_a"}, :broken, :broken})

    assert {:error, %Error{code: :kafka_publish_failed, detail: detail}} =
             Writer.put(client, message!(%{}, "body"))

    assert is_binary(detail)
  end

  test "publish эмитит телеметрию с результатом и топиком", %{client: client} do
    handler_id = "kafka-writer-#{inspect(self())}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:core, :mq, :kafka, :publish],
        fn
          _event, measurements, metadata, test_pid when test_pid == self() ->
            send(test_pid, {:publish, measurements, metadata})

          _event, _measurements, _metadata, _test_pid ->
            :ok
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert :ok = Writer.put(client, message!(%{"name" => "a"}, "a"))
    assert_received {:publish, %{count: 1, duration: duration}, %{result: :ok, topic: "topic_a"}}
    assert is_integer(duration)

    {:ok, missing} = Mq.Message.new(Mq.Topic.new!("missing"), %{}, "a", nil)
    assert {:error, _} = Writer.put(client, missing)
    assert_received {:publish, %{count: 1}, %{result: :error, topic: "missing"}}

    assert {:error, _} = Writer.put(client, message!(%{}, ""))
    refute_received {:publish, _, _}

    assert :ok = Task.await(Task.async(fn -> Writer.put(client, message!(%{}, "b")) end))
    refute_received {:publish, _, _}
  end

  defp message!(headers, body, key \\ Mq.Key.new!("owner-1")) do
    {:ok, message} = Mq.Message.new(Mq.Topic.new!("topic_a"), headers, body, key)

    message
  end
end
