defmodule Core.Mq.Kafka.Reader.StoreTest do
  use Core.DataCase, async: true

  alias Core.Error
  alias Core.Mq.Kafka.Reader.Store

  @ttl_ms 30_000

  setup do
    {:ok, subscriber: "sub-#{System.unique_integer([:positive])}", topic: "topic_a"}
  end

  test "свободная аренда берётся, занятая чужим токеном — нет", %{subscriber: sub, topic: topic} do
    first = Store.new_lease()
    second = Store.new_lease()

    assert :ok = Store.acquire(TestRepo, sub, topic, first, @ttl_ms)
    assert :taken = Store.acquire(TestRepo, sub, topic, second, @ttl_ms)
    assert :ok = Store.acquire(TestRepo, sub, topic, first, @ttl_ms)
  end

  test "аренда своя у пары подписчик-топик", %{subscriber: sub, topic: topic} do
    assert :ok = Store.acquire(TestRepo, sub, topic, Store.new_lease(), @ttl_ms)
    assert :ok = Store.acquire(TestRepo, sub, "topic_b", Store.new_lease(), @ttl_ms)
    assert :ok = Store.acquire(TestRepo, sub <> "-other", topic, Store.new_lease(), @ttl_ms)
  end

  test "commit под арендой пишет следующее смещение партиции", %{subscriber: sub, topic: topic} do
    lease = Store.new_lease()
    :ok = Store.acquire(TestRepo, sub, topic, lease, @ttl_ms)

    assert Store.offsets(TestRepo, sub, topic) == %{}

    assert :ok = Store.commit(TestRepo, sub, topic, lease, 0, 10)
    assert :ok = Store.commit(TestRepo, sub, topic, lease, 3, 7)
    assert :ok = Store.commit(TestRepo, sub, topic, lease, 0, 11)

    assert Store.offsets(TestRepo, sub, topic) == %{0 => 11, 3 => 7}
  end

  test "переход аренды: истёкшую берёт другая нода, устаревшая получает отказ commit", %{
    subscriber: sub,
    topic: topic
  } do
    stale = Store.new_lease()
    fresh = Store.new_lease()

    :ok = Store.acquire(TestRepo, sub, topic, stale, @ttl_ms)
    :ok = Store.commit(TestRepo, sub, topic, stale, 0, 5)

    expire!(sub, topic)

    assert :ok = Store.acquire(TestRepo, sub, topic, fresh, @ttl_ms)
    assert Store.offsets(TestRepo, sub, topic) == %{0 => 5}

    assert {:error, %Error{code: :kafka_lease_lost}} = Store.commit(TestRepo, sub, topic, stale, 0, 9)
    assert :taken = Store.acquire(TestRepo, sub, topic, stale, @ttl_ms)

    assert :ok = Store.commit(TestRepo, sub, topic, fresh, 0, 6)
    assert Store.offsets(TestRepo, sub, topic) == %{0 => 6}
  end

  test "commit с истёкшей арендой — отказ, даже если её никто не взял", %{subscriber: sub, topic: topic} do
    lease = Store.new_lease()
    :ok = Store.acquire(TestRepo, sub, topic, lease, @ttl_ms)
    expire!(sub, topic)

    assert {:error, %Error{code: :kafka_lease_lost}} = Store.commit(TestRepo, sub, topic, lease, 0, 1)
    assert :ok = Store.acquire(TestRepo, sub, topic, lease, @ttl_ms)
    assert :ok = Store.commit(TestRepo, sub, topic, lease, 0, 1)
  end

  test "release отдаёт аренду сразу", %{subscriber: sub, topic: topic} do
    lease = Store.new_lease()
    :ok = Store.acquire(TestRepo, sub, topic, lease, @ttl_ms)

    assert :ok = Store.release(TestRepo, sub, topic, lease)
    assert :ok = Store.acquire(TestRepo, sub, topic, Store.new_lease(), @ttl_ms)
  end

  test "release чужого токена аренду не трогает", %{subscriber: sub, topic: topic} do
    lease = Store.new_lease()
    :ok = Store.acquire(TestRepo, sub, topic, lease, @ttl_ms)

    assert :ok = Store.release(TestRepo, sub, topic, Store.new_lease())
    assert :taken = Store.acquire(TestRepo, sub, topic, Store.new_lease(), @ttl_ms)
  end

  defp expire!(sub, topic) do
    query =
      from(l in "mq_kafka_leases",
        where: l.subscriber_name == ^sub and l.topic == ^topic,
        update: [set: [locked_until: fragment("clock_timestamp() - interval '1 second'")]]
      )

    {1, _} = TestRepo.update_all(query, [])
  end
end
