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
    def store_offset(_topic, _sub, _offset), do: :ok
    def unsubscribe(_id), do: :ok

    def credit(id, n) do
      Agent.update(__MODULE__, fn credits -> credits ++ [{id, n}] end)
      :ok
    end

    def credits do
      Agent.get(__MODULE__, & &1)
    end
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
      start: {Agent, :start_link, [fn -> [] end, [name: FakeConn]]}
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
    {:ok, binary} = Mq.Codec.encode(message)
    binary
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
