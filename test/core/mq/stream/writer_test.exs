defmodule Core.Mq.Stream.WriterTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Core.Error
  alias Core.Mq
  alias Core.Mq.Message
  alias Core.Mq.Stream

  defmodule Log do
    @moduledoc false

    def start_link, do: Agent.start_link(fn -> [] end, name: __MODULE__)

    def add(entry), do: Agent.update(__MODULE__, &(&1 ++ [entry]))

    def entries, do: Agent.get(__MODULE__, & &1)

    def count(tag), do: Enum.count(entries(), &match?({^tag, _}, &1))
  end

  # Соединение — настоящий процесс под именем модуля: writer мониторит именно его,
  # а `producer_id` живёт не дольше этого процесса.
  defmodule FakeConn do
    @moduledoc false

    def start_link(opts) do
      state = Map.merge(%{sequence: 0, confirm?: true, declare: {:ok, 7}}, Map.new(opts))
      Agent.start_link(fn -> state end, name: __MODULE__)
    end

    def connect do
      Log.add({:connect, nil})
      :ok
    end

    def create_stream(_topic), do: :ok

    def declare_producer(topic, _ref) do
      Log.add({:declare, topic})
      Agent.get(__MODULE__, & &1.declare)
    end

    def producer_sequence(topic, _ref) do
      Log.add({:sequence, topic})

      Agent.get(__MODULE__, fn state -> {:ok, if(state.confirm?, do: state.sequence, else: 0)} end)
    end

    def publish(_producer_id, publishing_id, binary) do
      Log.add({:publish, publishing_id})
      Agent.update(__MODULE__, &%{&1 | sequence: publishing_id})
      _ = binary
      :ok
    end

    def delete_producer(producer_id) do
      Log.add({:delete_producer, producer_id})
      :ok
    end
  end

  defmodule ExitingConn do
    @moduledoc false

    def start_link(_opts), do: Agent.start_link(fn -> :ok end, name: __MODULE__)

    def connect, do: :ok

    def create_stream(_topic), do: :ok

    def declare_producer(_topic, _ref),
      do: exit({:timeout, {GenServer, :call, [__MODULE__, :declare_producer]}})
  end

  setup do
    start_supervised!(%{id: Log, start: {Log, :start_link, []}})
    :ok
  end

  test "подтверждённая пачка — :ok" do
    writer = start_writer(FakeConn, confirm?: true)

    assert :ok = Stream.Writer.put_many(writer, [message("a"), message("b")])
    assert Log.count(:publish) == 2
  end

  test "подготовка producer запрашивает подключение явно" do
    writer = start_writer(FakeConn, confirm?: true)

    assert :ok = Stream.Writer.put_many(writer, [message("a")])

    # lazy-соединение само не подключается: без явного connect/0 запросы буферизуются
    # до таймаута GenServer.call, и producer падает по exit вместо публикации.
    assert Log.count(:connect) == 1
  end

  test "штатная остановка удаляет объявленные producers" do
    writer = start_writer(FakeConn, confirm?: true)

    assert :ok = Stream.Writer.put_many(writer, [message("a")])
    assert Log.count(:delete_producer) == 0

    :ok = stop_supervised!(Stream.Writer)

    assert Log.count(:delete_producer) == 1
  end

  test "неподтверждённая публикация — ошибка, а не молчаливый :ok" do
    writer = start_writer(FakeConn, confirm?: false)

    log =
      capture_log(fn ->
        assert {:error, 0, %Error{code: :publish_unconfirmed}} =
                 Stream.Writer.put_many(writer, [message("a")])
      end)

    assert log =~ "публикация не подтверждена"
  end

  test "падение соединения сбрасывает кеш producers" do
    writer = start_writer(FakeConn, confirm?: true)

    assert :ok = Stream.Writer.put_many(writer, [message("a")])
    assert Log.count(:declare) == 1

    capture_log(fn ->
      conn = Process.whereis(FakeConn)
      ref = Process.monitor(conn)
      Process.exit(conn, :kill)
      assert_receive {:DOWN, ^ref, :process, _, _}
      await_restart(conn)

      assert :ok = Stream.Writer.put_many(writer, [message("b")])
    end)

    # Второй declare — доказательство, что кеш producer_id не пережил соединение.
    assert Log.count(:declare) == 2
  end

  test "exit соединения — ошибка публикации, writer жив" do
    writer = start_writer(ExitingConn, [])

    assert {:error, 0, %Error{code: :producer_setup_failed}} =
             Stream.Writer.put_many(writer, [message("a")])

    assert Process.alive?(writer)
  end

  # ---

  defp start_writer(conn, conn_opts) do
    start_supervised!(%{id: conn, start: {conn, :start_link, [conn_opts]}})

    start_supervised!(
      {Stream.Writer,
       connection: conn,
       reference_prefix: "test-writer",
       confirm_timeout_ms: 50,
       confirm_poll_ms: 5}
    )
  end

  defp await_restart(old_pid, attempts \\ 100) do
    case Process.whereis(FakeConn) do
      pid when is_pid(pid) and pid != old_pid ->
        pid

      _not_yet when attempts > 0 ->
        Process.sleep(5)
        await_restart(old_pid, attempts - 1)
    end
  end

  defp message(body) do
    {:ok, message} = Message.new(Mq.Topic.new!("writer_test"), %{}, body, Mq.Key.new!("agg-1"))
    message
  end
end
