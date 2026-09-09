defmodule Core.Mq.Stream.ReaderTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Core.Mq
  alias Core.Mq.Stream
  alias RabbitMQStream.Message.Types.DeliverData
  alias RabbitMQStream.OsirisChunk

  defmodule FakeConn do
    @moduledoc false

    def connect, do: :ok
    def create_stream(_topic), do: :ok
    def subscribe(_stream, _pid, _offset, _credit), do: {:ok, 1}
    def query_offset(_topic, _sub), do: {:error, :not_found}
    def unsubscribe(_id), do: :ok

    def store_offset(_topic, _sub, offset) do
      Agent.update(__MODULE__, &%{&1 | offsets: &1.offsets ++ [offset]})
      :ok
    end

    def credit(id, n) do
      Agent.update(__MODULE__, &%{&1 | credits: &1.credits ++ [{id, n}]})
      :ok
    end

    def credits, do: Agent.get(__MODULE__, & &1.credits)

    def offsets, do: Agent.get(__MODULE__, & &1.offsets)
  end

  defmodule FlakyConn do
    @moduledoc false

    def connect, do: :ok
    def create_stream(_topic), do: :ok
    def query_offset(_topic, _sub), do: {:error, :not_found}
    def store_offset(_topic, _sub, _offset), do: :ok
    def unsubscribe(_id), do: :ok
    def credit(_id, _n), do: :ok

    # Первые `failures` попыток подписки проваливаются, дальше — успех.
    def subscribe(_stream, _pid, _offset, _credit) do
      Agent.get_and_update(__MODULE__, fn
        0 -> {{:ok, 1}, 0}
        left -> {{:error, :econnrefused}, left - 1}
      end)
    end
  end

  setup do
    start_supervised!(%{
      id: FakeConn,
      start: {Agent, :start_link, [fn -> %{credits: [], offsets: []} end, [name: FakeConn]]}
    })

    topic = Mq.Topic.new!("reader_test")

    reader =
      start_supervised!(
        {Stream.Reader,
         connection: FakeConn,
         topic: topic,
         subscriber_name: Mq.SubscriberName.new!("sub"),
         reliable?: true,
         credit: 2,
         initial_offset: :first,
         retry_min_ms: 10,
         retry_max_ms: 20}
      )

    {:ok, reader: reader, topic: topic}
  end

  test "без consumer credit не выдаётся, buffer = все entries", %{reader: reader, topic: topic} do
    deliver(reader, 0, encoded_many(topic, 0, 50))
    deliver(reader, 50, encoded_many(topic, 50, 50))

    info = Stream.Reader.info(reader)
    assert info.buffer_len == 100
    assert info.chunk_remaining == 50
    assert FakeConn.credits() == []
  end

  test "credit только по исчерпании чанка", %{reader: reader, topic: topic} do
    deliver(reader, 0, encoded_many(topic, 0, 50))
    deliver(reader, 50, encoded_many(topic, 50, 50))

    consume(reader, 10)
    assert Stream.Reader.info(reader).buffer_len == 90
    assert FakeConn.credits() == []

    consume(reader, 40)
    assert Stream.Reader.info(reader).buffer_len == 50
    assert FakeConn.credits() == [{1, 1}]

    consume(reader, 49)
    assert Stream.Reader.info(reader).buffer_len == 1
    assert FakeConn.credits() == [{1, 1}]

    consume(reader, 1)
    assert Stream.Reader.info(reader).buffer_len == 0
    assert FakeConn.credits() == [{1, 1}, {1, 1}]
    assert :empty = Stream.Reader.get(reader, 0)
  end

  test "decode_drop уменьшает remainder и кредитует на последнем entry чанка", %{
    reader: reader,
    topic: topic
  } do
    drops = self()

    :ok =
      :telemetry.attach(
        "#{inspect(drops)}-decode-drop",
        [:core, :mq, :stream, :decode_drop],
        fn _event, %{count: count}, _meta, pid -> send(pid, {:drop, count}) end,
        drops
      )

    on_exit(fn -> :telemetry.detach("#{inspect(drops)}-decode-drop") end)

    good = encoded(topic, "ok")
    deliver(reader, 0, [good, "not-json", good])

    assert {:ok, %Mq.Message{body: "ok"}} = Stream.Reader.get(reader, 0)
    assert :ok = Stream.Reader.commit(reader)
    assert FakeConn.credits() == []

    assert {:ok, %Mq.Message{body: "ok"}} = Stream.Reader.get(reader, 0)
    assert :ok = Stream.Reader.commit(reader)
    assert FakeConn.credits() == [{1, 1}]
    assert_received {:drop, 1}
    assert :empty = Stream.Reader.get(reader, 0)
  end

  test "чанк с sub-entry batching дропается целиком", %{reader: reader, topic: topic} do
    drops = self()

    :ok =
      :telemetry.attach(
        "#{inspect(drops)}-sub-batch-drop",
        [:core, :mq, :stream, :decode_drop],
        fn _event, %{count: count}, _meta, pid -> send(pid, {:drop, count}) end,
        drops
      )

    :ok =
      :telemetry.attach(
        "#{inspect(drops)}-sub-batch-deliver",
        [:core, :mq, :stream, :deliver],
        fn _event, %{entries: entries}, _meta, pid -> send(pid, {:deliver, entries}) end,
        drops
      )

    on_exit(fn ->
      :telemetry.detach("#{inspect(drops)}-sub-batch-drop")
      :telemetry.detach("#{inspect(drops)}-sub-batch-deliver")
    end)

    log =
      capture_log(fn ->
        deliver_sub_batched(reader, 0, [encoded(topic, "ok")], 5)
      end)

    assert log =~ "чанк с sub-entry batching пропущен"

    # Дропнутый чанк виден и в deliver: drop-rate считается в одних единицах — entries.
    assert_received {:deliver, 1}
    assert_received {:drop, 1}
    assert :empty = Stream.Reader.get(reader, 0)
    assert Stream.Reader.info(reader).buffer_len == 0
    assert FakeConn.credits() == [{1, 1}]
  end

  test "запись с чужим topic'ом в конверте дропается", %{reader: reader} do
    drops = self()

    :ok =
      :telemetry.attach(
        "#{inspect(drops)}-topic-mismatch",
        [:core, :mq, :stream, :decode_drop],
        fn _event, %{count: count}, _meta, pid -> send(pid, {:drop, count}) end,
        drops
      )

    on_exit(fn -> :telemetry.detach("#{inspect(drops)}-topic-mismatch") end)

    alien = encoded(Mq.Topic.new!("alien_topic"), "body")

    log =
      capture_log(fn ->
        deliver(reader, 0, [alien])
        assert :empty = Stream.Reader.get(reader, 0)
      end)

    assert log =~ "topic конверта не совпадает с подпиской"
    assert_received {:drop, 1}
    assert Stream.Reader.info(reader).buffer_len == 0
  end

  test "серия дропов сохраняется одним offset", %{reader: reader} do
    deliver(reader, 7, ["not-json", "also-bad"])

    assert :empty = Stream.Reader.get(reader, 0)

    # Один `store_offset` на серию — с последним дропнутым offset: без него хвост из
    # нечитаемых записей перебирался бы после каждого рестарта.
    assert FakeConn.offsets() == [8]
  end

  test "накопленный дроп виден в info и сохраняется при остановке", %{
    reader: reader,
    topic: topic
  } do
    deliver(reader, 7, ["not-json", encoded(topic, "ok")])

    assert {:ok, %Mq.Message{body: "ok"}} = Stream.Reader.get(reader, 0)
    assert Stream.Reader.info(reader).dropped_offset == 7
    assert FakeConn.offsets() == []

    :ok = stop_supervised!(Stream.Reader)

    # Штатная остановка не отдаёт дроп назад брокеру: иначе тот же хвост переберётся
    # на следующем старте.
    assert FakeConn.offsets() == [7]
  end

  test "при reliable?: false дропы offset не пишут", %{topic: topic} do
    reader =
      start_supervised!(
        Supervisor.child_spec(
          {Stream.Reader,
           connection: FakeConn,
           topic: topic,
           subscriber_name: Mq.SubscriberName.new!("sub-unreliable"),
           reliable?: false,
           initial_offset: :first},
          id: :unreliable_reader
        )
      )

    deliver(reader, 3, ["not-json", "also-bad"])

    assert :empty = Stream.Reader.get(reader, 0)
    assert Stream.Reader.info(reader).dropped_offset == nil
    assert FakeConn.offsets() == []
  end

  test "commit подписчика перекрывает накопленные дропы", %{reader: reader, topic: topic} do
    deliver(reader, 7, ["not-json", encoded(topic, "ok")])

    assert {:ok, %Mq.Message{body: "ok"}} = Stream.Reader.get(reader, 0)
    assert :ok = Stream.Reader.commit(reader)

    assert FakeConn.offsets() == [8]
  end

  test "чужой topic логируется один раз на подписку", %{reader: reader} do
    alien = encoded(Mq.Topic.new!("alien_topic"), "body")

    log =
      capture_log(fn ->
        deliver(reader, 0, [alien, alien, alien])
        assert :empty = Stream.Reader.get(reader, 0)
      end)

    assert length(String.split(log, "topic конверта не совпадает")) - 1 == 1
  end

  test "мусор в :initial_offset — ArgumentError на старте, а не цикл рестартов", %{topic: topic} do
    Process.flag(:trap_exit, true)

    capture_log(fn ->
      assert {:error, {%ArgumentError{message: message}, _stack}} =
               Stream.Reader.start_link(
                 connection: FakeConn,
                 topic: topic,
                 subscriber_name: Mq.SubscriberName.new!("sub"),
                 initial_offset: :bogus
               )

      assert message =~ ":initial_offset"
    end)
  end

  test "topic не того типа — ArgumentError на старте", %{topic: topic} do
    Process.flag(:trap_exit, true)

    capture_log(fn ->
      assert {:error, {%ArgumentError{}, _stack}} =
               Stream.Reader.start_link(
                 connection: FakeConn,
                 topic: Mq.Topic.value(topic),
                 subscriber_name: Mq.SubscriberName.new!("sub")
               )
    end)
  end

  test "чанк из битых entries: get :empty и один credit", %{reader: reader} do
    deliver(reader, 0, ["bad-1", "bad-2", "bad-3"])

    assert :empty = Stream.Reader.get(reader, 0)
    assert Stream.Reader.info(reader).buffer_len == 0
    assert FakeConn.credits() == [{1, 1}]
  end

  describe "подписка вне init/1" do
    setup do
      start_supervised!(%{
        id: FlakyConn,
        start: {Agent, :start_link, [fn -> 2 end, [name: FlakyConn]]}
      })

      :ok
    end

    test "старт не падает при недоступном брокере, подписка поднимается ретраем" do
      topic = Mq.Topic.new!("flaky_test")

      reader =
        start_supervised!(
          Supervisor.child_spec(
            {Stream.Reader,
             connection: FlakyConn,
             topic: topic,
             subscriber_name: Mq.SubscriberName.new!("sub"),
             reliable?: true,
             credit: 2,
             initial_offset: :first,
             retry_min_ms: 10,
             retry_max_ms: 20},
            id: :flaky_reader
          )
        )

      # Первые две попытки подписки провалились, но процесс жив и отдаёт :empty.
      refute Stream.Reader.info(reader).subscribed?
      assert :empty = Stream.Reader.get(reader, 0)

      assert eventually(fn -> Stream.Reader.info(reader).subscribed? end)

      deliver(reader, 0, [encoded(topic, "after-retry")])
      assert {:ok, %Mq.Message{body: "after-retry"}} = Stream.Reader.get(reader, 0)
    end
  end

  describe "рестарт соединения" do
    test "подписка восстанавливается, буфер и pending сбрасываются", %{
      reader: reader,
      topic: topic
    } do
      deliver(reader, 0, encoded_many(topic, 0, 5))
      assert {:ok, %Mq.Message{}} = Stream.Reader.get(reader, 0)

      info = Stream.Reader.info(reader)
      assert info.buffer_len == 4
      assert info.pending?

      log =
        capture_log(fn ->
          conn = Process.whereis(FakeConn)
          ref = Process.monitor(conn)
          Process.exit(conn, :kill)
          assert_receive {:DOWN, ^ref, :process, _, _}

          # Пока подписки нет, reader отдаёт нейтральный :empty, а не ошибку.
          assert :empty = Stream.Reader.get(reader, 0)
          assert eventually(fn -> Stream.Reader.info(reader).subscribed? end)
        end)

      assert log =~ "подписка не удалась" or log =~ "stream reader подписан"

      # Записи прежней подписки не переезжают в новую: они придут заново от offset.
      info = Stream.Reader.info(reader)
      assert info.buffer_len == 0
      assert info.chunk_remaining == 0
      refute info.pending?
    end

    test "чанк после потери подписки не роняет reader", %{reader: reader} do
      conn = Process.whereis(FakeConn)
      ref = Process.monitor(conn)
      Process.exit(conn, :kill)
      assert_receive {:DOWN, ^ref, :process, _, _}

      capture_log(fn ->
        # Пустой чанк идёт сразу в grant_credit, где subscription_id уже nil.
        deliver(reader, 0, [])
        assert Process.alive?(reader)
        assert :empty = Stream.Reader.get(reader, 0)
      end)

      assert Process.alive?(reader)
    end
  end

  defp eventually(fun, attempts \\ 50) do
    Enum.reduce_while(1..attempts, false, fn _, _acc ->
      if fun.() do
        {:halt, true}
      else
        Process.sleep(10)
        {:cont, false}
      end
    end)
  end

  defp consume(reader, n) do
    for _ <- 1..n do
      assert {:ok, %Mq.Message{}} = Stream.Reader.get(reader, 0)
      assert :ok = Stream.Reader.commit(reader)
    end
  end

  defp encoded_many(topic, from, count) do
    Enum.map(from..(from + count - 1), fn i -> encoded(topic, "body-#{i}") end)
  end

  defp encoded(topic, body) do
    {:ok, message} = Mq.Message.new(topic, %{"name" => "n"}, body, Mq.Key.new!("agg-1"))
    {:ok, binary} = Stream.Codec.encode(message)
    binary
  end

  defp deliver_sub_batched(reader, chunk_id, entries, num_records) do
    chunk = %OsirisChunk{
      chunk_type: :chunk_user,
      num_entries: length(entries),
      num_records: num_records,
      timestamp: 0,
      epoch: 1,
      chunk_id: chunk_id,
      chunk_crc: 0,
      data_length: 0,
      trailer_length: 0,
      data_entries: entries
    }

    send(reader, {:deliver, %DeliverData{subscription_id: 1, osiris_chunk: chunk}})
    _ = Stream.Reader.info(reader)
    :ok
  end

  defp deliver(reader, chunk_id, entries) do
    n = length(entries)

    chunk = %OsirisChunk{
      chunk_type: :chunk_user,
      num_entries: n,
      num_records: n,
      timestamp: 0,
      epoch: 1,
      chunk_id: chunk_id,
      chunk_crc: 0,
      data_length: 0,
      trailer_length: 0,
      data_entries: entries
    }

    send(reader, {:deliver, %DeliverData{subscription_id: 1, osiris_chunk: chunk}})
    _ = Stream.Reader.info(reader)
    :ok
  end
end
