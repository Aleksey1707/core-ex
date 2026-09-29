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
end
