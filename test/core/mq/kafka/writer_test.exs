defmodule Core.Mq.Kafka.WriterTest do
  use ExUnit.Case, async: true

  alias Core.Error
  alias Core.Mq
  alias Core.Mq.Kafka.Writer

  defmodule OkClient do
    @moduledoc false

    def produce(record) do
      send(self(), {:produced, record})
      {:ok, record}
    end
  end

  defmodule FailClient do
    @moduledoc false

    def produce(record), do: {:error, %{record | error_code: 1}}
  end

  defmodule UnknownTopicClient do
    @moduledoc false

    def produce(_record) do
      raise "Error on add partition: {:error, :unkown_metadata_for_topic}"
    end
  end

  defmodule FailSecondClient do
    @moduledoc false

    def produce(%Klife.Record{value: "fail"} = record), do: {:error, %{record | error_code: 7}}
    def produce(record), do: {:ok, record}
  end

  test "publish эмитит телеметрию с результатом и топиком" do
    handler_id = "kafka-writer-#{inspect(self())}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:core, :mq, :kafka, :publish],
        fn _event, measurements, metadata, test_pid ->
          send(test_pid, {:publish, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert :ok = Writer.put(OkClient, message!(%{"name" => "a"}, "a"))
    assert_received {:publish, %{count: 1, duration: duration}, %{result: :ok, topic: "topic_a"}}
    assert is_integer(duration)

    assert {:error, _} = Writer.put(FailClient, message!(%{"name" => "a"}, "a"))
    assert_received {:publish, %{count: 1}, %{result: :error, topic: "topic_a"}}
  end

  test "put_many: успех по порядку" do
    messages = for name <- ~w(a b), do: message!(%{"name" => name}, name)

    assert :ok = Writer.put_many(OkClient, messages)
    assert_received {:produced, %Klife.Record{value: "a"}}
    assert_received {:produced, %Klife.Record{value: "b"}}
  end

  test "put: topic/key/value/headers → Klife.Record" do
    assert :ok = Writer.put(OkClient, message!(%{"owner_id" => "o-1"}, "body"))

    assert_received {:produced, record}

    assert %Klife.Record{
             topic: "topic_a",
             key: "owner-1",
             value: "body",
             headers: [%{key: "owner_id", value: "o-1"}]
           } = record
  end

  test "put: сообщение без заголовков" do
    assert :ok = Writer.put(OkClient, message!(%{}, "body"))
    assert_received {:produced, %Klife.Record{headers: []}}
  end

  test "put_many: стоп на первой ошибке" do
    messages = [
      message!(%{}, "ok-body"),
      message!(%{}, "fail"),
      message!(%{}, "tail")
    ]

    assert {:error, 1, %Error{code: :kafka_publish_failed}} =
             Writer.put_many(FailSecondClient, messages)
  end

  test "put: ошибка клиента" do
    assert {:error, %Error{code: :kafka_publish_failed, detail: 1}} =
             Writer.put(FailClient, message!(%{}, "body"))
  end

  test "produce: unkown_metadata_for_topic → unknown_metadata_for_topic" do
    assert {:error, %Error{code: :kafka_publish_failed, detail: :unknown_metadata_for_topic}} =
             Writer.put(UnknownTopicClient, message!(%{}, "body"))
  end

  defp message!(headers, body) do
    {:ok, message} =
      Mq.Message.new(Mq.Topic.new!("topic_a"), headers, body, Mq.Key.new!("owner-1"))

    message
  end
end
