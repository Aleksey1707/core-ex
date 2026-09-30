defmodule Core.Mq.Dlq.RoundTripTest do
  # Writer, читатель и подписчики — процессы со своими соединениями: sandbox в shared mode.
  use Core.DataCase, async: false

  import ExUnit.CaptureLog

  alias Core.Context
  alias Core.Error
  alias Core.Mq
  alias Core.Mq.Dlq
  alias Core.Mq.Message
  alias Core.MqFake
  alias Core.PubSub.MqSubscriberReliable

  require Error

  @topic Mq.Topic.new!("orders")

  setup do
    subscriber = Mq.SubscriberName.new!("dlq-#{System.unique_integer([:positive])}")
    writer = :"dlq_writer_#{System.unique_integer([:positive])}"
    start_supervised!({Dlq.Writer, repo: TestRepo, subscriber_name: subscriber, name: writer})

    {:ok, subscriber: subscriber, writer: writer}
  end

  describe "выброс и перечитывание без искажения" do
    test "tombstone, байтовый ключ, заголовок не в UTF-8 и позиция Kafka", ctx do
      assert_round_trip(ctx, message(nil, Mq.Key.new!(<<0, 255, 1>>), %Mq.Position{partition: 3, offset: 42}))
    end

    test "key: nil, пустое тело и позиция Stream без партиции", ctx do
      assert_round_trip(ctx, message("", nil, %Mq.Position{partition: nil, offset: 7}))
    end

    test "без позиции источника — пусто", ctx do
      assert_round_trip(ctx, message("body", Mq.Key.new!("agg-1"), nil))
    end
  end

  test "строка несёт топик источника, причину, ошибку, попытки и позицию", ctx do
    reject(ctx, message("body", nil, %Mq.Position{partition: 1, offset: 5}))

    assert %{rows: [[topic, reason, error, attempts, partition, offset, status, names]]} =
             TestRepo.query!(
               "SELECT topic, reason, error, attempts, source_partition, source_offset, status, header_names " <>
                 "FROM mq_dlq WHERE subscriber_name = $1",
               [Mq.SubscriberName.value(ctx.subscriber)]
             )

    assert {topic, reason, attempts, partition, offset, status} == {"orders", "rejected", 1, 1, 5, "dead"}
    assert error =~ "не загрузить"
    assert names == ~w(name trace)
  end

  test "до requeue читатель пуст, commit помечает запись processed", ctx do
    reject(ctx, message("body", nil, nil))
    reader = start_reader(ctx)

    assert :empty = Dlq.Reader.get(reader, 0)
    assert Dlq.requeue(TestRepo, {:topic, @topic}) == 1
    assert {:ok, first} = Dlq.Reader.get(reader, 0)
    assert {:ok, ^first} = Dlq.Reader.get(reader, 0)
    assert :ok = Dlq.Reader.commit(reader)
    assert :empty = Dlq.Reader.get(reader, 0)
    assert statuses(ctx) == ["processed"]
  end

  test "повторный отказ перечитанного — новая запись dead, прежняя processed", ctx do
    reject(ctx, message("body", nil, nil))
    Dlq.requeue(TestRepo, :all)

    sub = start_sub(start_reader(ctx), Dlq.Reader, ctx, "resub", &rejecting/3)
    capture_log(fn -> assert :dlq = MqSubscriberReliable.run_once(sub) end)

    assert statuses(ctx) == ~w(processed dead)
  end

  # ---

  defp assert_round_trip(ctx, original) do
    parent = self()
    reject(ctx, original)

    assert Dlq.requeue(TestRepo, :all) == 1

    on_message = fn message, _data, _context ->
      send(parent, {:reread, message})
      :ok
    end

    sub = start_sub(start_reader(ctx), Dlq.Reader, ctx, "reread", on_message)

    assert :processed = MqSubscriberReliable.run_once(sub)
    assert_received {:reread, ^original}
    assert :idle = MqSubscriberReliable.run_once(sub)
    assert statuses(ctx) == ["processed"]
  end

  defp reject(ctx, original) do
    source = MqFake.QueueReader.new([original])
    sub = start_sub(source, MqFake.QueueReader, ctx, "source", &rejecting/3)

    capture_log(fn -> assert :dlq = MqSubscriberReliable.run_once(sub) end)
    stop_supervised!({:sub, "source"})
  end

  defp rejecting(_message, _data, _context),
    do: {:reject, Error.app(__MODULE__, code: :invariant, ns: :pubsub, message: "не загрузить никогда")}

  defp start_sub(reader, reader_module, ctx, name, on_message) do
    opts = [
      reader_module: reader_module,
      reader: reader,
      from_message: fn m -> {:ok, m} end,
      on_message: on_message,
      topic: Mq.Topic.value(@topic),
      poll_interval_ms: 60_000,
      dlq_writer: Dlq.Writer,
      dlq_handle: ctx.writer
    ]

    sub = start_supervised!({MqSubscriberReliable, opts}, id: {:sub, name})
    :ok = MqSubscriberReliable.subscribe(sub, nil, Context.new())
    sub
  end

  defp start_reader(ctx) do
    start_supervised!({Dlq.Reader, repo: TestRepo, topic: @topic, subscriber_name: ctx.subscriber})
  end

  defp message(body, key, position) do
    headers = [{"Name", "order_created"}, {"trace", <<0xFF, 0xFE>>}]
    {:ok, message} = Message.new(@topic, headers, body, key, position)

    message
  end

  defp statuses(ctx) do
    %{rows: rows} =
      TestRepo.query!("SELECT status FROM mq_dlq WHERE subscriber_name = $1 ORDER BY id", [
        Mq.SubscriberName.value(ctx.subscriber)
      ])

    List.flatten(rows)
  end
end
