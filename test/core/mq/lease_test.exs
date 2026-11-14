defmodule Core.Mq.LeaseTest do
  use Core.DataCase, async: true

  alias Core.Error
  alias Core.Mq.Dlq.Store, as: DlqStore
  alias Core.Mq.Kafka.Reader.Store, as: KafkaStore
  alias Core.Mq.Lease

  test "new_token — UUID в 16 байтах, токены не повторяются" do
    tokens = for _ <- 1..100, do: Lease.new_token()

    assert Enum.all?(tokens, &(byte_size(&1) == 16))
    assert tokens == Enum.uniq(tokens)
  end

  test "deadline считает срок от текущего момента и знает :infinity" do
    before = System.monotonic_time(:millisecond)

    deadline = Lease.deadline(1_000)

    assert deadline >= before + 1_000
    assert deadline <= before + 2_000
    assert Lease.deadline(:infinity) == :infinity
  end

  test "lost_error — один код, ns и текст, scope и ключи адаптера — в detail" do
    kafka = Lease.lost_error(:kafka, %{topic: "orders", partition: 2})
    dlq = Lease.lost_error(:dlq, %{id: 7})

    assert %Error{kind: :app, code: :lease_lost, ns: :mq, message: message} = kafka
    assert %Error{code: :lease_lost, ns: :mq, message: ^message} = dlq
    assert kafka.detail == %{scope: :kafka, topic: "orders", partition: 2}
    assert dlq.detail == %{scope: :dlq, id: 7}
  end

  test "оба хранилища сообщают потерю аренды одной формой" do
    subscriber = "sub-#{System.unique_integer([:positive])}"
    topic = "orders"
    dlq_id = insert_dlq!(subscriber, topic)

    assert {:error, %Error{} = kafka} =
             KafkaStore.commit(TestRepo, subscriber, topic, KafkaStore.new_lease(), 0, 1)

    assert {:error, %Error{} = dlq} = DlqStore.commit(TestRepo, dlq_id, DlqStore.new_lease())

    assert %Error{kind: :app, ns: :mq, code: :lease_lost, message: message} = kafka
    assert %Error{kind: :app, ns: :mq, code: :lease_lost, message: ^message} = dlq
    assert kafka.detail == %{scope: :kafka, topic: topic, partition: 0}
    assert dlq.detail == %{scope: :dlq, id: dlq_id}
  end

  # ---

  defp insert_dlq!(subscriber, topic) do
    :ok =
      DlqStore.insert(TestRepo, %{
        subscriber: subscriber,
        topic: topic,
        key: nil,
        header_names: [],
        header_values: [],
        body: "a",
        partition: nil,
        offset: nil,
        reason: "rejected",
        error: nil,
        attempts: 1
      })

    %{rows: [[id]]} = TestRepo.query!("SELECT max(id) FROM mq_dlq WHERE subscriber_name = $1", [subscriber])
    id
  end
end
