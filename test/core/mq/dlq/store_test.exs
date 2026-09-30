defmodule Core.Mq.Dlq.StoreTest do
  use Core.DataCase, async: true

  alias Core.Error
  alias Core.Mq
  alias Core.Mq.Dlq
  alias Core.Mq.Dlq.Store

  @ttl_ms 30_000

  setup do
    {:ok, subscriber: "sub-#{System.unique_integer([:positive])}", topic: "orders"}
  end

  describe "захват" do
    test "свободная запись requeued захватывается одним токеном", %{subscriber: sub, topic: topic} do
      id = insert!(sub, topic, "a")
      requeue!([id])

      assert {:ok, %{id: ^id, body: "a"}} = Store.claim(TestRepo, sub, topic, Store.new_lease(), @ttl_ms)
      assert :none = Store.claim(TestRepo, sub, topic, Store.new_lease(), @ttl_ms)
    end

    test "запись dead и чужой подписчик или топик не захватываются", %{subscriber: sub, topic: topic} do
      insert!(sub, topic, "dead")
      requeue!([insert!(sub <> "-other", topic, "other-sub"), insert!(sub, "payments", "other-topic")])

      assert :none = Store.claim(TestRepo, sub, topic, Store.new_lease(), @ttl_ms)
    end

    test "записи захватываются по возрастанию id", %{subscriber: sub, topic: topic} do
      ids = for body <- ~w(a b c), do: insert!(sub, topic, body)
      requeue!(ids)

      bodies =
        for _ <- ids do
          {:ok, claimed} = Store.claim(TestRepo, sub, topic, Store.new_lease(), @ttl_ms)
          claimed.body
        end

      assert bodies == ~w(a b c)
    end

    test "истёкший захват перехватывает другой токен, commit устаревшего отклоняется", %{
      subscriber: sub,
      topic: topic
    } do
      id = insert!(sub, topic, "a")
      requeue!([id])
      stale = Store.new_lease()
      fresh = Store.new_lease()

      assert {:ok, %{id: ^id}} = Store.claim(TestRepo, sub, topic, stale, 1)
      Process.sleep(5)
      assert {:ok, %{id: ^id}} = Store.claim(TestRepo, sub, topic, fresh, @ttl_ms)

      assert :lost = Store.hold(TestRepo, id, stale, @ttl_ms)
      assert {:error, %Error{code: :dlq_lease_lost}} = Store.commit(TestRepo, id, stale)
      assert :ok = Store.hold(TestRepo, id, fresh, @ttl_ms)
      assert :ok = Store.commit(TestRepo, id, fresh)
      assert status(id) == "processed"
    end

    test "release отдаёт захват сразу", %{subscriber: sub, topic: topic} do
      id = insert!(sub, topic, "a")
      requeue!([id])
      lease = Store.new_lease()

      {:ok, _} = Store.claim(TestRepo, sub, topic, lease, @ttl_ms)
      assert :ok = Store.release(TestRepo, id, lease)
      assert {:ok, %{id: ^id}} = Store.claim(TestRepo, sub, topic, Store.new_lease(), @ttl_ms)
    end
  end

  describe "requeue" do
    test "по id, по топику и все — только записи dead", %{subscriber: sub, topic: topic} do
      a = insert!(sub, topic, "a")
      b = insert!(sub, topic, "b")
      c = insert!(sub, "payments", "c")

      assert Dlq.requeue(TestRepo, [a]) == 1
      assert Dlq.requeue(TestRepo, [a]) == 0
      assert Dlq.requeue(TestRepo, {:topic, Mq.Topic.new!("payments")}) == 1
      assert status(b) == "dead"
      assert status(c) == "requeued"
      assert Dlq.requeue(TestRepo, :all) == 1
      assert status(b) == "requeued"
    end
  end

  test "counts отдаёт все статусы пары подписчик-топик, отсутствующий — нулём", %{subscriber: sub, topic: topic} do
    insert!(sub, topic, "a")
    requeue!([insert!(sub, topic, "b"), insert!(sub, topic, "c")])

    counts = for %{subscriber: ^sub} = row <- Dlq.counts(TestRepo), into: %{}, do: {row.status, row.count}

    assert counts == %{"dead" => 1, "requeued" => 2, "processed" => 0}
  end

  # ---

  defp insert!(sub, topic, body) do
    :ok =
      Store.insert(TestRepo, %{
        subscriber: sub,
        topic: topic,
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

    %{rows: [[id]]} = TestRepo.query!("SELECT max(id) FROM mq_dlq WHERE subscriber_name = $1", [sub])
    id
  end

  defp requeue!(ids), do: Dlq.requeue(TestRepo, ids)

  defp status(id) do
    %{rows: [[status]]} = TestRepo.query!("SELECT status FROM mq_dlq WHERE id = $1", [id])
    status
  end
end
