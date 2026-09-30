defmodule Core.Mq.Kafka.ReaderTest do
  # Читатель ходит в Postgres из своего процесса с первого тика аренды: общий sandbox.
  use Core.DataCase, async: false

  import ExUnit.CaptureLog

  alias Core.Error
  alias Core.KafkaFake
  alias Core.Mq
  alias Core.Mq.Kafka.Reader
  alias Core.Mq.Kafka.Reader.Store

  @topic "topic_a"
  @sub "sub"

  setup do
    client = :"kafka_reader_fake_#{System.unique_integer([:positive])}"
    start_supervised!({KafkaFake, client: client, topics: %{@topic => 2}})

    {:ok, client: client}
  end

  test "get отдаёт запись с ключом, заголовками, телом и позицией; commit пишет смещение и ack", %{client: client} do
    reader = start_reader!(client)
    await_subscribed(client, 0)

    :ok = KafkaFake.deliver(client, @topic, 0, [{5, "k-1", "body", [{"Name", "created"}]}], 10)

    assert {:ok, message} = Reader.get(reader, 100)
    assert message.topic == Mq.Topic.new!(@topic)
    assert message.key == Mq.Key.new!("k-1")
    assert message.headers == %{"name" => "created"}
    assert message.body == "body"
    assert message.position == %Mq.Position{partition: 0, offset: 5}

    assert :ok = Reader.commit(reader)
    assert Store.offsets(TestRepo, @sub, @topic) == %{0 => 6}
    assert %{acks: [5]} = KafkaFake.subscription(client, @topic, 0)
    assert :empty = Reader.get(reader, 0)
  end

  test "get без commit отдаёт то же сообщение", %{client: client} do
    reader = start_reader!(client)
    await_subscribed(client, 0)

    :ok = KafkaFake.deliver(client, @topic, 0, [{0, "k", "a", []}, {1, "k", "b", []}], 2)

    assert {:ok, %{body: "a"}} = Reader.get(reader, 100)
    assert {:ok, %{body: "a"}} = Reader.get(reader, 0)
    assert :ok = Reader.commit(reader)
    assert {:ok, %{body: "b"}} = Reader.get(reader, 0)
  end

  test "commit без сообщения в работе — ошибка", %{client: client} do
    reader = start_reader!(client)

    assert {:error, %Error{code: :nothing_to_commit}} = Reader.commit(reader)
  end

  test "пустые ключ и значение — key: nil и tombstone", %{client: client} do
    reader = start_reader!(client)
    await_subscribed(client, 0)

    :ok = KafkaFake.deliver(client, @topic, 0, [{0, "", "", []}], 1)

    assert {:ok, %Mq.Message{key: nil, body: nil}} = Reader.get(reader, 100)
  end

  test "без смещения — подписка с earliest, опцией — с latest", %{client: client} do
    start_reader!(client)
    await_subscribed(client, 0)

    assert %{begin_offset: :earliest} = KafkaFake.subscription(client, @topic, 1)

    other = :"kafka_reader_fake_#{System.unique_integer([:positive])}"
    start_supervised!(Supervisor.child_spec({KafkaFake, client: other, topics: %{@topic => 1}}, id: other))
    start_reader!(other, subscriber_name: Mq.SubscriberName.new!("latest"), initial_offset: :latest, name: :latest)
    await_subscribed(other, 0)

    assert %{begin_offset: :latest} = KafkaFake.subscription(other, @topic, 0)
  end

  test "после рестарта чтение продолжается с зафиксированного смещения", %{client: client} do
    lease = Store.new_lease()
    :ok = Store.acquire(TestRepo, @sub, @topic, lease, 30_000)
    :ok = Store.commit(TestRepo, @sub, @topic, lease, 1, 42)
    :ok = Store.release(TestRepo, @sub, @topic, lease)

    start_reader!(client)
    await_subscribed(client, 1)

    assert %{begin_offset: 42} = KafkaFake.subscription(client, @topic, 1)
    assert %{begin_offset: :earliest} = KafkaFake.subscription(client, @topic, 0)
  end

  test "партиции обходятся по кругу", %{client: client} do
    reader = start_reader!(client)
    await_subscribed(client, 1)

    :ok = KafkaFake.deliver(client, @topic, 0, [{0, "k", "a0", []}, {1, "k", "a1", []}], 2)
    :ok = KafkaFake.deliver(client, @topic, 1, [{0, "k", "b0", []}, {1, "k", "b1", []}], 2)

    bodies =
      for _ <- 1..4 do
        {:ok, %{body: body}} = Reader.get(reader, 100)
        :ok = Reader.commit(reader)
        body
      end

    assert bodies == ~w(a0 b0 a1 b1)
  end

  test "нода без аренды не подписана и отдаёт :empty", %{client: client} do
    :ok = Store.acquire(TestRepo, @sub, @topic, Store.new_lease(), 30_000)

    reader = start_reader!(client)

    assert :empty = Reader.get(reader, 50)
    assert %{subscriber: nil} = KafkaFake.subscription(client, @topic, 0)
    assert %{lease?: false} = Reader.info(reader)
  end

  test "устаревшая нода: commit отказывает, подписка и сообщение в работе сбрасываются", %{client: client} do
    reader = start_reader!(client)
    await_subscribed(client, 0)

    :ok = KafkaFake.deliver(client, @topic, 0, [{0, "k", "a", []}], 1)
    assert {:ok, _} = Reader.get(reader, 100)

    take_over!()

    log =
      capture_log(fn ->
        assert {:error, %Error{code: :kafka_lease_lost}} = Reader.commit(reader)
      end)

    assert log =~ "аренда"
    assert Store.offsets(TestRepo, @sub, @topic) == %{}
    assert :empty = Reader.get(reader, 0)
    assert %{subscriber: nil} = KafkaFake.subscription(client, @topic, 0)
  end

  test "аренда, перехваченная при продлении, — отписка и :empty", %{client: client} do
    reader = start_reader!(client, lease_ttl_ms: 300)
    await_subscribed(client, 0)

    capture_log(fn ->
      take_over!()
      await(fn -> KafkaFake.subscription(client, @topic, 0).subscriber == nil end)
    end)

    assert :empty = Reader.get(reader, 0)
  end

  test "остановленная нода отдаёт аренду, следующая берёт её сразу", %{client: client} do
    reader = start_reader!(client)
    await_subscribed(client, 0)
    stop_supervised!(Reader)
    refute Process.alive?(reader)

    assert :ok = Store.acquire(TestRepo, @sub, @topic, Store.new_lease(), 30_000)
  end

  test "OFFSET_OUT_OF_RANGE — error в лог, телеметрия сброса и переподписка с earliest", %{client: client} do
    lease = Store.new_lease()
    :ok = Store.acquire(TestRepo, @sub, @topic, lease, 30_000)
    :ok = Store.commit(TestRepo, @sub, @topic, lease, 0, 100)
    :ok = Store.release(TestRepo, @sub, @topic, lease)

    attach_telemetry([:core, :mq, :kafka, :offset_reset])

    start_reader!(client)
    await_subscribed(client, 0)
    assert %{begin_offset: 100, subscribes: 1} = KafkaFake.subscription(client, @topic, 0)

    log =
      capture_log(fn ->
        :ok = KafkaFake.fetch_error(client, @topic, 0, :offset_out_of_range)
        await(fn -> KafkaFake.subscription(client, @topic, 0).subscribes == 2 end)
      end)

    assert log =~ "offset_out_of_range" or log =~ "вне лога"
    assert %{begin_offset: :earliest} = KafkaFake.subscription(client, @topic, 0)
    assert_receive {:telemetry, %{count: 1}, %{topic: @topic, partition: 0}}
  end

  test "перезапуск консьюмера — переподписка с зафиксированного смещения", %{client: client} do
    reader = start_reader!(client)
    await_subscribed(client, 0)

    :ok = KafkaFake.deliver(client, @topic, 0, [{7, "k", "a", []}, {8, "k", "b", []}], 9)
    assert {:ok, %{body: "a"}} = Reader.get(reader, 100)
    assert :ok = Reader.commit(reader)
    assert {:ok, %{body: "b"}} = Reader.get(reader, 0)

    log =
      capture_log(fn ->
        :ok = KafkaFake.restart_consumer(client, @topic, 0)
        await(fn -> KafkaFake.subscription(client, @topic, 0).subscriber == reader end)
      end)

    assert log =~ "переподписка"
    assert %{begin_offset: 8} = KafkaFake.subscription(client, @topic, 0)
    assert {:error, %Error{code: :nothing_to_commit}} = Reader.commit(reader)
  end

  test "неизвестный топик — ошибка в лог, читатель жив и отдаёт :empty", %{client: client} do
    log =
      capture_log(fn ->
        reader = start_reader!(client, topic: Mq.Topic.new!("missing"))
        assert :empty = Reader.get(reader, 50)
        assert Process.alive?(reader)
      end)

    assert log =~ "unknown_topic_or_partition"
  end

  test "новые партиции получают подписку", %{client: client} do
    reader = start_reader!(client, partitions_interval_ms: 20)
    await_subscribed(client, 1)

    :ok = KafkaFake.set_partitions(client, @topic, 3)

    capture_log(fn -> await(fn -> subscribed?(client, 2, reader) end) end)

    assert subscribed?(client, 0, reader)
    assert subscribed?(client, 1, reader)
  end

  test "info: high_wm_offset последней пачки и ts последнего закоммиченного по партиции", %{client: client} do
    reader = start_reader!(client)
    await_subscribed(client, 0)

    :ok = KafkaFake.deliver(client, @topic, 0, [{3, "k", "a", []}], 17)
    assert {:ok, _} = Reader.get(reader, 100)
    assert :ok = Reader.commit(reader)

    assert %{lease?: true, pending?: false, topic: @topic, partitions: %{0 => partition}} = Reader.info(reader)
    assert partition == %{high_wm_offset: 17, committed_offset: 4, committed_ts: 3, buffered: 0}
  end

  test "мусор в опциях — ArgumentError на старте", %{client: client} do
    Process.flag(:trap_exit, true)

    for opts <- [[initial_offset: :first], [prefetch_count: 0], [repo: "TestRepo"]] do
      assert {:error, {%ArgumentError{}, _}} = Reader.start_link(reader_opts(client, opts))
    end
  end

  defp start_reader!(client, opts \\ []) do
    start_supervised!({Reader, reader_opts(client, opts)})
  end

  defp reader_opts(client, opts) do
    Keyword.merge(
      [
        client: client,
        topic: Mq.Topic.new!(@topic),
        subscriber_name: Mq.SubscriberName.new!(@sub),
        repo: TestRepo,
        retry_min_ms: 10,
        retry_max_ms: 20
      ],
      opts
    )
  end

  defp take_over! do
    query =
      from(l in "mq_kafka_leases",
        where: l.subscriber_name == ^@sub and l.topic == ^@topic,
        update: [set: [locked_until: fragment("clock_timestamp() - interval '1 second'")]]
      )

    {1, _} = TestRepo.update_all(query, [])
    :ok = Store.acquire(TestRepo, @sub, @topic, Store.new_lease(), 30_000)
  end

  defp await_subscribed(client, partition) do
    await(fn -> is_pid(KafkaFake.subscription(client, @topic, partition).subscriber) end)
  end

  defp subscribed?(client, partition, reader) do
    match?([_], :ets.lookup(client, {:consumer, @topic, partition})) and
      KafkaFake.subscription(client, @topic, partition).subscriber == reader
  end

  defp await(fun, attempts \\ 200) do
    cond do
      fun.() ->
        :ok

      attempts > 0 ->
        Process.sleep(5)
        await(fun, attempts - 1)

      true ->
        flunk("условие не наступило")
    end
  end

  defp attach_telemetry(event) do
    test = self()
    handler = "#{inspect(test)}-#{inspect(event)}"

    :ok =
      :telemetry.attach(
        handler,
        event,
        fn _event, measurements, metadata, pid -> send(pid, {:telemetry, measurements, metadata}) end,
        test
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end
end
