defmodule Core.Mq.Dlq.ReaderContractTest do
  # Читатель — процесс со своим соединением: sandbox в shared mode.
  use Core.DataCase, async: false
  use Core.MqReaderContract, impl: Core.Mq.Dlq.Reader

  alias Core.Mq
  alias Core.Mq.Dlq
  alias Core.Mq.Dlq.Store

  @topic Mq.Topic.new!("orders")

  test "metrics pending: 1 после get, 0 после commit", context do
    reader = start_reader(context)

    assert :ok = publish(reader, "pending")
    assert {:ok, _message} = Core.Mq.Dlq.Reader.get(reader, 15_000)
    assert %{pending: 1} = Core.Mq.Dlq.Reader.metrics(reader)
    assert :ok = Core.Mq.Dlq.Reader.commit(reader)
    assert %{pending: 0} = Core.Mq.Dlq.Reader.metrics(reader)
  end

  def start_reader(_context) do
    subscriber = Mq.SubscriberName.new!("dlq_contract_#{System.unique_integer([:positive])}")

    reader =
      start_supervised!({Core.Mq.Dlq.Reader, repo: TestRepo, topic: @topic, subscriber_name: subscriber})

    Process.put(:reader_contract_sinks, Map.put(Process.get(:reader_contract_sinks, %{}), reader, subscriber))
    reader
  end

  def publish(reader, body) do
    subscriber = Map.fetch!(Process.get(:reader_contract_sinks), reader)
    subscriber = Mq.SubscriberName.value(subscriber)

    :ok =
      Store.insert(TestRepo, %{
        subscriber: subscriber,
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
