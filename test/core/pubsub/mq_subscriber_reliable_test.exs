defmodule Core.PubSub.MqSubscriberReliableTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Core.Context
  alias Core.Error
  alias Core.Mq
  alias Core.Mq.Message
  alias Core.MqFake
  alias Core.PubSub.MqSubscriberReliable
  alias Core.Repo

  require Error

  setup do
    topic = Mq.Topic.new!("products")

    {:ok,
     topic: topic,
     reader: MqFake.QueueReader.new([message(topic, "body")]),
     context: Context.new()}
  end

  test "два подписчика читают свои очереди независимо", %{topic: topic, context: context} do
    parent = self()

    on = fn message, data, _ctx ->
      send(parent, {:got, data, message.body})
      :ok
    end

    a = start_sub(MqFake.QueueReader.new([message(topic, "body")]), topic, "sub-a", on)
    b = start_sub(MqFake.QueueReader.new([message(topic, "body")]), topic, "sub-b", on)

    assert :ok = MqSubscriberReliable.subscribe(a, :a, context)
    assert :ok = MqSubscriberReliable.subscribe(b, :b, context)

    assert :processed = MqSubscriberReliable.run_once(a)
    assert :processed = MqSubscriberReliable.run_once(b)

    assert_receive {:got, :a, "body"}
    assert_receive {:got, :b, "body"}
  end

  test "ошибка handler → без commit, redelivery", %{
    reader: reader,
    topic: topic,
    context: context
  } do
    parent = self()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    on = fn _message, _data, _ctx ->
      n = Agent.get_and_update(counter, &{&1, &1 + 1})

      if n == 0 do
        send(parent, :failed)
        {:error, Error.app(__MODULE__, code: :fail, ns: :pubsub, message: "boom")}
      else
        send(parent, :ok)
        :ok
      end
    end

    sub = start_sub(reader, topic, "sub-retry", on)
    assert :ok = MqSubscriberReliable.subscribe(sub, nil, context)

    log =
      capture_log(fn ->
        assert :error = MqSubscriberReliable.run_once(sub)
      end)

    assert_receive :failed
    assert log =~ "pubsub reliable on_message: boom"

    assert :processed = MqSubscriberReliable.run_once(sub)
    assert_receive :ok
  end

  test "исключение в on_message → без commit, subscriber не падает, redelivery", %{
    reader: reader,
    topic: topic,
    context: context
  } do
    parent = self()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    on = fn _message, _data, _ctx ->
      n = Agent.get_and_update(counter, &{&1, &1 + 1})

      if n == 0 do
        send(parent, :raised)
        raise "boom"
      else
        send(parent, :ok)
        :ok
      end
    end

    sub = start_sub(reader, topic, "sub-crash", on)
    assert :ok = MqSubscriberReliable.subscribe(sub, nil, context)

    log =
      capture_log(fn ->
        assert :error = MqSubscriberReliable.run_once(sub)
      end)

    assert_receive :raised
    assert log =~ "pubsub reliable on_message"
    assert Process.alive?(sub)

    assert :processed = MqSubscriberReliable.run_once(sub)
    assert_receive :ok
  end

  test "исключение в from_message → без commit, subscriber не падает", %{
    reader: reader,
    topic: topic,
    context: context
  } do
    {:ok, sub} =
      start_supervised(
        {MqSubscriberReliable,
         reader_module: MqFake.QueueReader,
         reader: reader,
         from_message: fn _m -> raise "decode boom" end,
         on_message: fn _m, _d, _c -> :ok end,
         topic: Mq.Topic.value(topic),
         poll_interval_ms: 60_000},
        id: {:sub, "sub-from-crash"}
      )

    assert :ok = MqSubscriberReliable.subscribe(sub, nil, context)

    log =
      capture_log(fn ->
        assert :error = MqSubscriberReliable.run_once(sub)
      end)

    assert log =~ "pubsub reliable from_message"
    assert Process.alive?(sub)
  end

  test "{:skip, _} → commit", %{reader: reader, topic: topic, context: context} do
    on = fn _message, _data, _ctx -> {:skip, :ignored} end
    sub = start_sub(reader, topic, "sub-skip", on)

    assert :ok = MqSubscriberReliable.subscribe(sub, nil, context)
    assert :processed = MqSubscriberReliable.run_once(sub)
    assert :idle = MqSubscriberReliable.run_once(sub)
  end

  test "drain: один :tick обрабатывает пачку без ожидания poll_interval", %{context: context} do
    topic = Mq.Topic.new!("drain_topic")
    reader = MqFake.QueueReader.new(Enum.map(1..5, &message(topic, "b#{&1}")))

    parent = self()
    attach_cycle_telemetry(parent)

    on = fn _message, _data, _ctx ->
      send(parent, :handled)
      :ok
    end

    sub = start_sub(reader, topic, "sub-drain", on)
    assert :ok = MqSubscriberReliable.subscribe(sub, nil, context)

    send(sub, :tick)

    for _ <- 1..5 do
      assert_receive :handled, 500
      assert_receive {:cycle, :processed}, 500
    end

    assert_receive {:cycle, :idle}, 500
    refute_receive :handled, 200
  end

  test "контекст живёт одно сообщение: shadow copy не растёт", %{topic: topic, context: context} do
    reader = MqFake.QueueReader.new(Enum.map(1..3, &message(topic, "b#{&1}")))
    parent = self()

    on = fn _message, _data, ctx ->
      send(parent, {:ctx, ctx})
      :ok
    end

    sub =
      start_sub(reader, topic, "sub-ctx", on,
        context_factory: fn -> Repo.Sc.init(Context.new()) end
      )

    assert :ok = MqSubscriberReliable.subscribe(sub, nil, context)

    for _ <- 1..3, do: assert(:processed = MqSubscriberReliable.run_once(sub))

    contexts =
      for _ <- 1..3,
          do:
            (
              assert_received {:ctx, ctx}
              ctx
            )

    # у каждого сообщения свой контекст, и его ETS-таблица удалена после обработки
    unique = Enum.uniq(contexts)

    assert length(unique) == 3

    assert Enum.all?(contexts, fn ctx ->
             :ets.info(Context.find(ctx, :shadow_copy)) == :undefined
           end)
  end

  describe "ядовитое сообщение" do
    test "после max_attempts уходит в DLQ и коммитится", %{
      reader: reader,
      topic: topic,
      context: context
    } do
      dlq = MqFake.Writer.new()
      parent = self()
      attach_dlq_telemetry(parent)

      on = fn _message, _data, _ctx ->
        {:error, Error.app(__MODULE__, code: :poison, ns: :pubsub, message: "яд")}
      end

      sub =
        start_sub(reader, topic, "sub-poison", on,
          dlq_writer: MqFake.Writer,
          dlq_handle: dlq,
          max_attempts: 3
        )

      assert :ok = MqSubscriberReliable.subscribe(sub, nil, context)

      log =
        capture_log(fn ->
          assert :error = MqSubscriberReliable.run_once(sub)
          assert :error = MqSubscriberReliable.run_once(sub)
          assert :dlq = MqSubscriberReliable.run_once(sub)
        end)

      assert log =~ "сообщение отправлено в DLQ после 3 попыток"
      assert_receive {:dlq, %{topic: "products", dlq_topic: "products.dlq"}}

      # сообщение закоммичено — топик разблокирован
      assert :idle = MqSubscriberReliable.run_once(sub)
      assert MqFake.QueueReader.pending(reader) == 0

      assert [dead] = MqFake.Writer.published(dlq)
      assert dead.body == "body"
      assert Mq.Topic.value(dead.topic) == "products.dlq"
      assert Mq.Message.find_header(dead, Mq.HeaderKey.new!("x-dlq-source-topic")) == "products"
      assert Mq.Message.find_header(dead, Mq.HeaderKey.new!("x-dlq-attempts")) == "3"
      assert Mq.Message.find_header(dead, Mq.HeaderKey.new!("x-dlq-error")) =~ "яд"
    end

    test "сбой публикации в DLQ не теряет сообщение", %{
      reader: reader,
      topic: topic,
      context: context
    } do
      dlq = MqFake.Writer.new(fail_at: 0)

      on = fn _message, _data, _ctx ->
        {:error, Error.app(__MODULE__, code: :poison, ns: :pubsub, message: "яд")}
      end

      sub =
        start_sub(reader, topic, "sub-dlq-down", on,
          dlq_writer: MqFake.Writer,
          dlq_handle: dlq,
          max_attempts: 1
        )

      assert :ok = MqSubscriberReliable.subscribe(sub, nil, context)

      log =
        capture_log(fn ->
          assert :error = MqSubscriberReliable.run_once(sub)
        end)

      assert log =~ "не удалось отправить сообщение в DLQ"
      assert MqFake.QueueReader.pending(reader) == 1
    end

    test "без dlq_writer сообщение остаётся в топике", %{
      reader: reader,
      topic: topic,
      context: context
    } do
      on = fn _message, _data, _ctx ->
        {:error, Error.app(__MODULE__, code: :poison, ns: :pubsub, message: "яд")}
      end

      sub = start_sub(reader, topic, "sub-no-dlq", on, max_attempts: 1)
      assert :ok = MqSubscriberReliable.subscribe(sub, nil, context)

      log =
        capture_log(fn ->
          assert :error = MqSubscriberReliable.run_once(sub)
        end)

      assert log =~ "DLQ не настроен"
      assert MqFake.QueueReader.pending(reader) == 1
    end

    test "успех сбрасывает счётчик попыток", %{topic: topic, context: context} do
      reader = MqFake.QueueReader.new([message(topic, "first"), message(topic, "second")])
      dlq = MqFake.Writer.new()
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      on = fn _message, _data, _ctx ->
        n = Agent.get_and_update(counter, &{&1, &1 + 1})

        if n == 0,
          do: {:error, Error.app(__MODULE__, code: :once, ns: :pubsub, message: "разок")},
          else: :ok
      end

      sub =
        start_sub(reader, topic, "sub-reset", on,
          dlq_writer: MqFake.Writer,
          dlq_handle: dlq,
          max_attempts: 2
        )

      assert :ok = MqSubscriberReliable.subscribe(sub, nil, context)

      capture_log(fn ->
        assert :error = MqSubscriberReliable.run_once(sub)
      end)

      # вторая попытка того же сообщения успешна: счётчик обнулён,
      # следующее сообщение начинает с первой попытки
      assert :processed = MqSubscriberReliable.run_once(sub)
      assert :processed = MqSubscriberReliable.run_once(sub)
      assert MqFake.Writer.published(dlq) == []
    end
  end

  test "unsubscribe + subscribe не удваивают цикл опроса", %{
    reader: reader,
    topic: topic,
    context: context
  } do
    parent = self()
    attach_cycle_telemetry(parent)

    on = fn _message, _data, _ctx ->
      send(parent, :handled)
      :ok
    end

    sub = start_sub(reader, topic, "sub-timer", on, poll_interval_ms: 30)

    assert :ok = MqSubscriberReliable.subscribe(sub, nil, context)
    assert :ok = MqSubscriberReliable.unsubscribe(sub, context)
    assert :ok = MqSubscriberReliable.subscribe(sub, nil, context)

    assert_receive :handled, 500
    refute_receive :handled, 200
  end

  # ---

  defp start_sub(reader, topic, name, on_message, opts \\ []) do
    child_opts =
      [
        reader_module: MqFake.QueueReader,
        reader: reader,
        from_message: fn m -> {:ok, m} end,
        on_message: on_message,
        topic: Mq.Topic.value(topic),
        poll_interval_ms: 60_000
      ]
      |> Keyword.merge(opts)

    {:ok, sub} = start_supervised({MqSubscriberReliable, child_opts}, id: {:sub, name})

    sub
  end

  defp message(topic, body) do
    {:ok, message} =
      Message.new(topic, %{"name" => "product_created"}, body, Mq.Key.new!("agg-1"))

    message
  end

  defp attach_cycle_telemetry(parent) do
    attach("cycle", [:core, :mq, :subscriber, :cycle], parent, fn metadata ->
      {:cycle, metadata.result}
    end)
  end

  defp attach_dlq_telemetry(parent) do
    attach("dlq", [:core, :mq, :subscriber, :dlq], parent, fn metadata ->
      {:dlq, metadata}
    end)
  end

  defp attach(prefix, event, parent, to_message) do
    handler_id = "sub-#{prefix}-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        event,
        fn _event, _measurements, metadata, test_pid ->
          send(test_pid, to_message.(metadata))
        end,
        parent
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end
