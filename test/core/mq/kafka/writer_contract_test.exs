defmodule Core.Mq.Kafka.WriterContractTest do
  use ExUnit.Case, async: true
  use Core.MqWriterContract, impl: Core.Mq.Kafka.Writer

  alias Core.KafkaFake
  alias Core.Mq

  # ---

  defp ok_writer, do: start_client(nil)

  defp failing_writer(index), do: start_client(index)

  defp start_client(fail_at) do
    client = :"kafka_fake_#{System.unique_integer([:positive])}"
    start_supervised!({KafkaFake, client: client, topics: %{"contract" => 1}, fail_at: fail_at})

    client
  end

  defp published(client), do: Enum.map(KafkaFake.published(client), & &1.value)

  defp message(body) do
    {:ok, message} = Mq.Message.new(Mq.Topic.new!("contract"), %{}, body, Mq.Key.new!("agg-1"))

    message
  end
end
