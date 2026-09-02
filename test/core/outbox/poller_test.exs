defmodule Core.Outbox.PollerTest do
  use Core.DataCase, async: false

  import ExUnit.CaptureLog

  alias Core.Context
  alias Core.Error
  alias Core.Mq
  alias Core.MqFake
  alias Core.Outbox
  alias Core.Outbox.Delivery
  alias Core.Outbox.Poller
  alias Core.Outbox.Record
  alias Core.Outbox.Repo.Pg.Schema

  @repo Application.compile_env!(:core, Core.Outbox.Repo)

  defmodule ExitingWriter do
    @moduledoc false

    def put(writer, message), do: put_many(writer, [message])

    def put_many(_writer, _messages),
      do: exit({:noproc, {GenServer, :call, [:writer, :put_many]}})
  end

  defmodule SlowWriter do
    @moduledoc false

    def put(writer, message) do
      put_many(writer, [message])
    end

    def put_many({writer, delay_ms}, messages) when is_list(messages) do
      Process.sleep(delay_ms)
      MqFake.Writer.put_many(writer, messages)
    end
  end

  setup do
    writer = MqFake.Writer.new()
    handler_id = "outbox-poller-#{inspect(self())}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:core, :outbox, :poller, :cycle],
          [:core, :outbox, :delivery]
        ],
        fn event, measurements, metadata, test_pid ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, context: Context.new(), writer: writer}
  end

  defp start_poller(delivery, opts \\ []) do
    max_attempts = Keyword.get(opts, :max_attempts, 3)
    batch_size = Keyword.get(opts, :batch_size, 10)
    poll_interval_ms = Keyword.get(opts, :poll_interval_ms, 60_000)
    idle_min_ms = Keyword.get(opts, :idle_min_ms, 50)
    name = Keyword.get(opts, :name)

    child_opts =
      [
        repo: @repo,
        delivery: delivery,
        poll_interval_ms: poll_interval_ms,
        idle_min_ms: idle_min_ms,
        batch_size: Outbox.BatchSize.new!(batch_size),
        lock_duration: Outbox.LockDuration.new!(30),
        max_attempts: Outbox.Attempts.new!(max_attempts)
      ]
      |> then(fn opts -> if name, do: Keyword.put(opts, :name, name), else: opts end)

    {:ok, poller} = start_supervised({Poller, child_opts})
    poller
  end

  test "child_spec: :id равен :name, иначе модуль" do
    assert %{id: Poller} = Poller.child_spec([])
    assert %{id: :notifications} = Poller.child_spec(name: :notifications)
  end

  defp append_record(context, name) do
    {:ok, record} =
      Record.new(
        Outbox.Topic.new!("products"),
        Outbox.Key.new!("agg-1"),
        Outbox.Name.new!(name),
        %{"n" => name},
        %{"name" => name, "aggr_id" => "agg-1"}
      )

    :ok = @repo.append([record], context)
    record
  end

  defp status_of(id) do
    id_str = Outbox.ID.format(id, :full)
    TestRepo.one(from(r in Schema, where: r.id == ^id_str, select: r.status))
  end

  defp capture_module_logs(module, level, fun) do
    Logger.put_module_level(module, level)

    try do
      capture_log(fun)
    after
      Logger.delete_module_level(module)
    end
  end

  test "run_once публикует в MQ и помечает published", %{writer: writer, context: context} do
    record = append_record(context, "created")
    delivery = Delivery.Mq.new(MqFake.Writer, writer)
    poller = start_poller(delivery)

    log =
      capture_module_logs(Poller, :debug, fn ->
        assert :processed = Poller.run_once(poller)
      end)

    assert status_of(record.id) == :published
    assert log =~ "Опрос outbox: пакет size=1 опубликовано=1 повтор=0 провалено=0"
    assert log =~ "Outbox опубликован: id=#{Outbox.ID.format(record.id, :hex)}"

    assert_receive {:telemetry, [:core, :outbox, :delivery], %{count: 1},
                    %{outcome: :published, topic: "products"}}

    assert_receive {:telemetry, [:core, :outbox, :poller, :cycle], measurements,
                    %{result: :processed}}

    assert measurements.batch_size == 1
    assert measurements.published == 1
    assert measurements.retry == 0
    assert measurements.failed == 0
    assert is_integer(measurements.duration)

    assert [message] = MqFake.Writer.published(writer)
    assert message.body == Jason.encode!(%{"n" => "created"})
    assert Mq.Message.find_header(message, Mq.HeaderKey.new!("name")) == "created"
    assert Mq.Message.find_header(message, Mq.HeaderKey.new!("aggr_id")) == "agg-1"
  end

  test "сбой delivery → retry (status new)", %{context: context} do
    record = append_record(context, "retry")
    delivery = Delivery.Mq.new(MqFake.Writer, MqFake.Writer.new(fail_at: 0))
    poller = start_poller(delivery, max_attempts: 3)

    log =
      capture_log(fn ->
        assert :processed = Poller.run_once(poller)
      end)

    assert status_of(record.id) == :new
    assert log =~ "Ошибка доставки outbox, будет повтор"
    assert log =~ "ошибка=publish failed at 0"

    assert_receive {:telemetry, [:core, :outbox, :delivery], %{count: 1},
                    %{outcome: :retry, topic: "products"}}

    assert_receive {:telemetry, [:core, :outbox, :poller, :cycle], measurements,
                    %{result: :processed}}

    assert measurements.retry == 1

    _ =
      capture_log(fn ->
        assert :processed = Poller.run_once(poller)
      end)

    assert status_of(record.id) == :new
  end

  test "сбой delivery при max_attempts → failed", %{context: context} do
    record = append_record(context, "fail")
    delivery = Delivery.Mq.new(MqFake.Writer, MqFake.Writer.new(fail_at: 0))
    poller = start_poller(delivery, max_attempts: 1)

    log =
      capture_module_logs(Poller, :debug, fn ->
        assert :processed = Poller.run_once(poller)
      end)

    assert status_of(record.id) == :failed
    assert log =~ "Outbox окончательно провален"
    assert log =~ "Опрос outbox: пакет size=1 опубликовано=0 повтор=0 провалено=1"

    assert_receive {:telemetry, [:core, :outbox, :delivery], %{count: 1},
                    %{outcome: :failed, topic: "products"}}

    assert_receive {:telemetry, [:core, :outbox, :poller, :cycle], measurements,
                    %{result: :processed}}

    assert measurements.failed == 1
  end

  test "пустой outbox → idle", %{writer: writer} do
    delivery = Delivery.Mq.new(MqFake.Writer, writer)
    poller = start_poller(delivery)

    log =
      capture_module_logs(Poller, :info, fn ->
        assert :idle = Poller.run_once(poller)
      end)

    refute log =~ "Опрос outbox: пакет"

    assert_receive {:telemetry, [:core, :outbox, :poller, :cycle], measurements, %{result: :idle}}

    assert measurements.batch_size == 0
    refute_received {:telemetry, [:core, :outbox, :delivery], _, _}
  end

  test "drain: два батча подряд через :tick", %{writer: writer, context: context} do
    _r1 = append_record(context, "d1")
    _r2 = append_record(context, "d2")
    delivery = Delivery.Mq.new(MqFake.Writer, writer)

    poller =
      start_poller(delivery,
        batch_size: 1,
        poll_interval_ms: 60_000,
        idle_min_ms: 60_000
      )

    send(poller, :tick)

    assert_receive {:telemetry, [:core, :outbox, :poller, :cycle], _, %{result: :processed}},
                   500

    assert_receive {:telemetry, [:core, :outbox, :poller, :cycle], _, %{result: :processed}},
                   500

    assert_receive {:telemetry, [:core, :outbox, :poller, :cycle], _, %{result: :idle}},
                   500
  end

  test "wake публикует без ожидания poll_interval", %{writer: writer, context: context} do
    record = append_record(context, "wake_me")
    delivery = Delivery.Mq.new(MqFake.Writer, writer)
    name = :"outbox-poller-wake-#{System.unique_integer([:positive])}"
    poller = start_poller(delivery, poll_interval_ms: 60_000, idle_min_ms: 60_000, name: name)

    assert :ok = Poller.wake(poller)

    assert_receive {:telemetry, [:core, :outbox, :poller, :cycle], _, %{result: :processed}},
                   500

    assert status_of(record.id) == :published
  end

  test "fail-stop: ошибка в середине батча не публикует хвост", %{context: context} do
    r1 = append_record(context, "ok1")
    r2 = append_record(context, "fail")
    r3 = append_record(context, "tail")

    delivery = Delivery.Mq.new(MqFake.Writer, MqFake.Writer.new(fail_at: 1))
    poller = start_poller(delivery, max_attempts: 3)

    _ =
      capture_log(fn ->
        assert :processed = Poller.run_once(poller)
      end)

    assert status_of(r1.id) == :published
    assert status_of(r2.id) == :new
    assert status_of(r3.id) == :new

    assert [msg1] = MqFake.Writer.published(delivery.writer)
    assert msg1.body == Jason.encode!(%{"n" => "ok1"})

    assert_receive {:telemetry, [:core, :outbox, :poller, :cycle], measurements,
                    %{result: :processed}}

    assert measurements.published == 1
    assert measurements.retry == 2
    assert measurements.failed == 0
  end

  test "wake coalesce: много :wake не раздувают mailbox", %{writer: writer, context: context} do
    _record = append_record(context, "slow")
    delivery = Delivery.Mq.new(SlowWriter, {writer, 80})
    poller = start_poller(delivery, poll_interval_ms: 60_000, idle_min_ms: 60_000)

    send(poller, :tick)
    Enum.each(1..50, fn _ -> send(poller, :wake) end)

    assert_receive {:telemetry, [:core, :outbox, :poller, :cycle], _, %{result: :processed}},
                   1000

    # дать flush_wakes + возможный re-arm от drained wakes
    _ = :sys.get_state(poller)
    {:message_queue_len, len} = Process.info(poller, :message_queue_len)
    assert len < 10
  end

  test "append внутри TX будит poller только после commit", %{writer: writer, context: context} do
    delivery = Delivery.Mq.new(MqFake.Writer, writer)
    name = :"outbox-poller-tx-#{System.unique_integer([:positive])}"
    _poller = start_poller(delivery, poll_interval_ms: 60_000, idle_min_ms: 60_000, name: name)

    previous = Application.get_env(:core, Outbox, [])

    Application.put_env(
      :core,
      Outbox,
      Keyword.put(previous, :poller_name, name)
    )

    on_exit(fn -> Application.put_env(:core, Outbox, previous) end)

    {:ok, record} =
      Record.new(
        Outbox.Topic.new!("products"),
        Outbox.Key.new!("agg-1"),
        Outbox.Name.new!("tx_wake"),
        %{"n" => "tx_wake"}
      )

    assert {:ok, :ok} =
             TestRepo.transact(fn ->
               :ok = @repo.append([record], context)
               refute_received {:telemetry, [:core, :outbox, :poller, :cycle], _, _}
               {:ok, :ok}
             end)

    assert_receive {:telemetry, [:core, :outbox, :poller, :cycle], _, %{result: :processed}},
                   500

    assert status_of(record.id) == :published
  end

  test "exit из delivery не роняет poller и не теряет запись", %{context: context} do
    record = append_record(context, "exiting")
    delivery = Delivery.Mq.new(ExitingWriter, :unused)
    poller = start_poller(delivery)

    log =
      capture_module_logs(Poller, :error, fn ->
        assert {:error, %Error{code: :cycle_exit}} = Poller.run_once(poller)
      end)

    assert log =~ "Сбой цикла опроса outbox: exit"
    assert Process.alive?(poller)

    # Аренда снята сразу после сбоя: запись доступна следующему циклу, а не висит
    # `:in_work` до истечения lock_duration.
    assert status_of(record.id) == :new

    assert_receive {:telemetry, [:core, :outbox, :poller, :cycle], _, %{result: :error}}

    log =
      capture_module_logs(Poller, :error, fn ->
        assert {:error, %Error{code: :cycle_exit}} = Poller.run_once(poller)
      end)

    assert log =~ "Сбой цикла опроса outbox: exit"
    assert Process.alive?(poller)
  end

  test "нечитаемая строка помечается failed и не блокирует пачку", %{
    writer: writer,
    context: context
  } do
    poisoned = append_record(context, "poisoned")
    healthy = append_record(context, "healthy")

    poisoned_id = Outbox.ID.format(poisoned.id, :full)
    {1, _} = TestRepo.update_all(from(r in Schema, where: r.id == ^poisoned_id), set: [topic: ""])

    delivery = Delivery.Mq.new(MqFake.Writer, writer)
    poller = start_poller(delivery)

    log =
      capture_module_logs(Core.Outbox.Repo.Pg, :error, fn ->
        assert :processed = Poller.run_once(poller)
      end)

    assert log =~ "Outbox: строка не разобрана, помечена failed"
    assert status_of(poisoned.id) == :failed
    assert status_of(healthy.id) == :published

    errors =
      TestRepo.one(from(r in Schema, where: r.id == ^poisoned_id, select: r.errors))

    assert [%{"attempt" => 1, "message" => message}] = errors
    assert is_binary(message)
  end
end
