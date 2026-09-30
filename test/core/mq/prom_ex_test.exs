defmodule Core.Mq.PromExTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Core.Mq.PromEx

  defmodule StubReader do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts[:info], name: opts[:name])
    def init(info), do: {:ok, info}
    def handle_call(:info, _from, info), do: {:reply, info, info}
  end

  @readers {__MODULE__, :readers, []}

  @doc false
  def readers, do: [%{component: "orders", name: :missing_reader}]

  @doc false
  def twins, do: [%{component: "orders", name: :mq_promex_first}, %{component: "orders", name: :mq_promex_second}]

  test "event_metrics и polling_metrics непусты" do
    opts = [otp_app: :core, poll_rate: 5_000, readers: @readers]

    assert [%{metrics: event_metrics}] = List.wrap(PromEx.event_metrics(opts))
    assert event_metrics != []

    names =
      event_metrics
      |> Enum.map(&Enum.join(&1.name, "."))

    assert Enum.any?(names, &String.contains?(&1, "mq.publish"))
    assert Enum.any?(names, &String.contains?(&1, "mq.deliver.entries"))
    assert Enum.any?(names, &String.contains?(&1, "mq.decode_drop"))
    assert Enum.any?(names, &String.contains?(&1, "mq.subscriber.cycles"))
    assert "core.prom_ex.mq.collect.errors.total" in names

    dlq = Enum.find(event_metrics, &(&1.name == [:core, :prom_ex, :mq, :subscriber, :dlq, :total]))
    assert dlq.tags == [:topic, :dlq_topic, :reason]

    assert dlq.tag_values.(%{topic: "t", dlq_topic: "t.dlq", reason: :rejected}) == %{
             topic: "t",
             dlq_topic: "t.dlq",
             reason: "rejected"
           }

    assert [%{metrics: poll_metrics, poll_rate: 5_000}] =
             List.wrap(PromEx.polling_metrics(opts))

    poll_names =
      poll_metrics
      |> Enum.map(&Enum.join(&1.name, "."))

    assert Enum.any?(poll_names, &String.contains?(&1, "mq.reader.buffer_len"))
    assert Enum.any?(poll_names, &String.contains?(&1, "mq.reader.chunk_remaining"))
    assert Enum.any?(poll_names, &String.contains?(&1, "mq.reader.pending"))
  end

  test "без readers polling-группа не строится" do
    assert [] = PromEx.polling_metrics(otp_app: :core)
  end

  test "execute_reader_metrics no-op без живого reader" do
    handler_id = "mq-promex-#{inspect(self())}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:prom_ex, :plugin, :mq, :reader, :buffer_len],
        fn event, measurements, metadata, test_pid ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert :ok = PromEx.execute_reader_metrics(@readers)
    refute_received {:telemetry, [:prom_ex, :plugin, :mq, :reader, :buffer_len], _, _}
  end

  test "повтор component и topic: subscribed — минимум, buffer_len — сумма, error в лог" do
    on_exit(fn ->
      for {{Core.PromEx.Labels, _source} = key, _value} <- :persistent_term.get(), do: :persistent_term.erase(key)
    end)

    info = %{
      buffer_len: 2,
      chunk_remaining: 1,
      dropped_offset: nil,
      pending?: false,
      subscribed?: true,
      topic: "orders"
    }

    start_supervised!(%{id: :first, start: {StubReader, :start_link, [[name: :mq_promex_first, info: info]]}})

    start_supervised!(%{
      id: :second,
      start: {StubReader, :start_link, [[name: :mq_promex_second, info: %{info | subscribed?: false}]]}
    })

    handler_id = "mq-promex-dup-#{inspect(self())}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        [[:prom_ex, :plugin, :mq, :reader, :subscribed], [:prom_ex, :plugin, :mq, :reader, :buffer_len]],
        fn event, measurements, metadata, test_pid -> send(test_pid, {:telemetry, event, measurements, metadata}) end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    log = capture_log(fn -> PromEx.execute_reader_metrics({__MODULE__, :twins, []}) end)

    meta = %{component: "orders", topic: "orders"}
    assert_receive {:telemetry, [:prom_ex, :plugin, :mq, :reader, :subscribed], %{value: 0}, ^meta}
    assert_receive {:telemetry, [:prom_ex, :plugin, :mq, :reader, :buffer_len], %{value: 4}, ^meta}
    assert log =~ "source=mq_readers"
    assert capture_log(fn -> PromEx.execute_reader_metrics({__MODULE__, :twins, []}) end) == ""
  end

  test "отказ одного reader'а — отказ сбора группы readers, а не component; остальные собраны" do
    info = %{
      buffer_len: 1,
      chunk_remaining: 0,
      dropped_offset: nil,
      pending?: false,
      subscribed?: true,
      topic: "orders"
    }

    start_supervised!(%{id: :first, start: {StubReader, :start_link, [[name: :mq_promex_first, info: info]]}})
    down = spawn(fn -> receive do: (_call -> exit(:down)) end)
    Process.register(down, :mq_promex_second)
    handler_id = "mq-promex-collect-#{inspect(self())}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        [[:prom_ex, :plugin, :mq, :collect, :error], [:prom_ex, :plugin, :mq, :reader, :buffer_len]],
        fn event, measurements, metadata, test_pid -> send(test_pid, {:telemetry, event, measurements, metadata}) end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    log = capture_log(fn -> assert :ok = PromEx.execute_reader_metrics({__MODULE__, :twins, []}) end)

    assert log =~ "сбор метрик пропущен (mq reader orders)"
    assert_receive {:telemetry, [:prom_ex, :plugin, :mq, :collect, :error], %{count: 1}, %{collector: :readers}}
    assert_receive {:telemetry, [:prom_ex, :plugin, :mq, :reader, :buffer_len], %{value: 1}, %{component: "orders"}}
  end

  test "одна component с разными topic — не повтор" do
    info = %{
      buffer_len: 0,
      chunk_remaining: 0,
      dropped_offset: nil,
      pending?: false,
      subscribed?: true,
      topic: "orders"
    }

    start_supervised!(%{id: :first, start: {StubReader, :start_link, [[name: :mq_promex_first, info: info]]}})

    start_supervised!(%{
      id: :second,
      start: {StubReader, :start_link, [[name: :mq_promex_second, info: %{info | topic: "payments"}]]}
    })

    assert capture_log(fn -> PromEx.execute_reader_metrics({__MODULE__, :twins, []}) end) == ""
  end

  describe "чтение Kafka" do
    @kafka_readers {__MODULE__, :kafka_readers, []}
    @lease [:prom_ex, :plugin, :mq, :kafka_reader, :lease]
    @lag_messages [:prom_ex, :plugin, :mq, :kafka_reader, :lag_messages]
    @lag_seconds [:prom_ex, :plugin, :mq, :kafka_reader, :lag_seconds]

    test "счётчики — sum по count: засев нулём не прибавляет единицу" do
      assert [%{metrics: metrics}] = PromEx.event_metrics(otp_app: :core)
      by_name = Map.new(metrics, &{&1.name, &1})

      for {name, tags} <- [
            {[:offset_reset, :total], [:topic]},
            {[:decode_drop, :total], [:topic]},
            {[:read_errors, :total], [:topic, :reason]},
            {[:commit_errors, :total], [:topic, :reason]}
          ] do
        assert %Telemetry.Metrics.Sum{measurement: :count, tags: ^tags} =
                 Map.fetch!(by_name, [:core, :prom_ex, :mq, :kafka | name])
      end

      read_errors = Map.fetch!(by_name, [:core, :prom_ex, :mq, :kafka, :read_errors, :total])
      assert read_errors.tag_values.(%{topic: "t", reason: :lease}) == %{topic: "t", reason: "lease"}
    end

    test "polling-группа строится только с kafka_readers:" do
      assert [] = PromEx.polling_metrics(otp_app: :core)

      assert [%{group_name: :mq_kafka_reader_poll_metrics, metrics: metrics}] =
               PromEx.polling_metrics(otp_app: :core, kafka_readers: @kafka_readers)

      assert Enum.map(metrics, & &1.name) == [
               [:core, :prom_ex, :mq, :kafka_reader, :lease],
               [:core, :prom_ex, :mq, :kafka_reader, :lag_messages],
               [:core, :prom_ex, :mq, :kafka_reader, :lag_seconds]
             ]
    end

    test "владелец аренды: отставание по партициям, неизвестное — без значения" do
      now = System.os_time(:millisecond)

      start_kafka_reader!(%{
        lease?: true,
        pending?: false,
        topic: "orders",
        partitions: %{
          0 => %{high_wm_offset: 10, committed_offset: 4, committed_ts: now - 5_000, buffered: 0},
          1 => %{high_wm_offset: nil, committed_offset: 3, committed_ts: nil, buffered: 0}
        }
      })

      attach([@lease, @lag_messages, @lag_seconds])
      assert :ok = PromEx.execute_kafka_reader_metrics(@kafka_readers)

      assert_receive {:telemetry, @lease, %{value: 1}, %{component: "orders", topic: "orders"}}
      assert_receive {:telemetry, @lag_messages, %{value: 6}, %{component: "orders", topic: "orders", partition: 0}}
      assert_receive {:telemetry, @lag_seconds, %{value: seconds}, %{partition: 0}}
      assert seconds >= 5 and seconds < 6
      refute_received {:telemetry, _event, _measurements, %{partition: 1}}
    end

    test "нода без аренды — нули по известным партициям" do
      start_kafka_reader!(%{
        lease?: false,
        pending?: false,
        topic: "orders",
        partitions: %{0 => %{high_wm_offset: nil, committed_offset: nil, committed_ts: nil, buffered: 0}}
      })

      attach([@lease, @lag_messages, @lag_seconds])
      assert :ok = PromEx.execute_kafka_reader_metrics(@kafka_readers)

      assert_receive {:telemetry, @lease, %{value: 0}, %{component: "orders", topic: "orders"}}
      assert_receive {:telemetry, @lag_messages, %{value: 0}, %{partition: 0}}
      assert_receive {:telemetry, @lag_seconds, %{value: 0}, %{partition: 0}}
    end

    test "метка partition — строка" do
      assert [%{metrics: metrics}] = PromEx.polling_metrics(otp_app: :core, kafka_readers: @kafka_readers)
      lag = Enum.find(metrics, &(&1.name == [:core, :prom_ex, :mq, :kafka_reader, :lag_messages]))

      assert lag.tag_values.(%{component: "c", topic: "t", partition: 3}) == %{
               component: "c",
               topic: "t",
               partition: "3"
             }
    end
  end

  @doc false
  def kafka_readers, do: [%{component: "orders", name: :mq_promex_kafka}]

  defp start_kafka_reader!(info) do
    start_supervised!(%{id: :kafka, start: {StubReader, :start_link, [[name: :mq_promex_kafka, info: info]]}})
  end

  defp attach(events) do
    handler_id = "mq-promex-kafka-#{inspect(self())}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        fn event, measurements, metadata, test_pid -> send(test_pid, {:telemetry, event, measurements, metadata}) end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end
