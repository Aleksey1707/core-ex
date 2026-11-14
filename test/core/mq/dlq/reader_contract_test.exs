defmodule Core.Mq.Dlq.ReaderContractTest do
  # Читатель — процесс со своим соединением: sandbox в shared mode.
  use Core.DataCase, async: false
  use Core.MqReaderContract, impl: Core.Mq.Dlq.Reader

  alias Core.Mq
  alias Core.Mq.Dlq
  alias Core.Mq.Dlq.Store

  @topic Mq.Topic.new!("orders")

  def start_reader(_context) do
    subscriber = Mq.SubscriberName.new!("dlq_contract_#{System.unique_integer([:positive])}")
    Process.put(:reader_contract_subscriber, Mq.SubscriberName.value(subscriber))

    start_supervised!({Core.Mq.Dlq.Reader, repo: TestRepo, topic: @topic, subscriber_name: subscriber})
  end

  def publish(_reader, body) do
    :ok =
      Store.insert(TestRepo, %{
        subscriber: Process.get(:reader_contract_subscriber),
        topic: "orders",
        key: nil,
        header_names: [],
        header_values: [],
        body: body,
        partition: nil,
        offset: nil,
        reason: "rejected",
        error: nil,
        attempts: 1
      })

    Dlq.requeue(TestRepo, :all)
    :ok
  end
end
