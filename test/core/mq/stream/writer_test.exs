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

    # `declare:` — результат для всех топиков либо карта «топик → результат».
    def declare_producer(topic, _ref) do
      Log.add({:declare, topic})

      case Agent.get(__MODULE__, & &1.declare) do
        %{} = by_topic -> Map.get(by_topic, topic, {:ok, 7})
        result -> result
      end
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

  # Брокер подтверждает `slow_a` медленно (45 мс), а `slow_b` — только с четвёртого
  # опроса: с дедлайном на каждый топик пачка подтвердилась бы, с общим — нет.
  defmodule SlowConfirmConn do
    @moduledoc false

    def start_link(_opts), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

    def connect, do: :ok

    def create_stream(_topic), do: :ok

    def declare_producer(topic, _ref) do
      Log.add({:declare, topic})
      {:ok, producer_id(topic)}
    end

    def publish(producer_id, publishing_id, _binary) do
      Agent.update(__MODULE__, &Map.put(&1, producer_id, publishing_id))
      :ok
    end

    def producer_sequence("slow_a", _ref) do
      confirmed = Agent.get(__MODULE__, &Map.get(&1, producer_id("slow_a"), 0))
      if confirmed > 0, do: Process.sleep(45)

      {:ok, confirmed}
    end

    def producer_sequence("slow_b", _ref) do
      polls =
        Agent.get_and_update(__MODULE__, fn state ->
          polls = Map.get(state, :polls, 0) + 1
          {polls, Map.put(state, :polls, polls)}
        end)

      if polls > 4,
        do: {:ok, Agent.get(__MODULE__, &Map.get(&1, producer_id("slow_b"), 0))},
        else: {:ok, 0}
    end

    def delete_producer(producer_id) do
      Log.add({:delete_producer, producer_id})
      :ok
    end

    defp producer_id("slow_a"), do: 1
    defp producer_id("slow_b"), do: 2
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

  test "отказ посреди пачки с неподтверждённым началом — индекс 0" do
    writer = start_writer(FakeConn, confirm?: false, declare: %{"broken" => {:error, :access_refused}})

    capture_log(fn ->
      assert {:error, 0, %Error{code: :publish_unconfirmed}} =
               Stream.Writer.put_many(writer, [message("a"), message("b", "broken")])
    end)
  end

  test "отказ посреди пачки с подтверждённым началом — индекс отказа" do
    writer = start_writer(FakeConn, confirm?: true, declare: %{"broken" => {:error, :access_refused}})

    assert {:error, 1, %Error{code: :producer_setup_failed}} =
             Stream.Writer.put_many(writer, [message("a"), message("b", "broken")])
  end

  test "неподтверждённая пачка снимает producer, следующая объявляет его заново" do
    writer = start_writer(FakeConn, confirm?: false)

    capture_log(fn ->
      assert {:error, 0, %Error{code: :publish_unconfirmed}} =
               Stream.Writer.put_many(writer, [message("a")])

      assert {:error, 0, %Error{code: :publish_unconfirmed}} =
               Stream.Writer.put_many(writer, [message("b")])
    end)

    # Локальный sequence ушёл вперёд брокерского: кеш producer'а не переживает
    # неподтверждение, иначе сверка не сошлась бы уже никогда.
    assert Log.count(:declare) == 2
    assert Log.count(:delete_producer) == 2
  end

  test "дедлайн подтверждения — один на пачку, а не на каждый топик" do
    writer = start_writer(SlowConfirmConn, [])

    log =
      capture_log(fn ->
        assert {:error, 0, %Error{code: :publish_unconfirmed}} =
                 Stream.Writer.put_many(writer, [message("a", "slow_a"), message("b", "slow_b")])
      end)

    # Первый топик съел почти весь дедлайн пачки — второму осталось меньше, чем нужно
    # на подтверждение; с таймаутом на каждый топик ожидание было бы кратно их числу.
    assert log =~ "публикация не подтверждена topic=slow_b"
  end

  test "кеш producers ограничен: давний топик вытесняется" do
    start_supervised!(%{id: FakeConn, start: {FakeConn, :start_link, [[confirm?: true]]}})

    writer =
      start_supervised!(
        {Stream.Writer,
         connection: FakeConn,
         reference_prefix: "test-writer",
         confirm_timeout_ms: 50,
         confirm_poll_ms: 5,
         max_producers: 1}
      )

    assert :ok = Stream.Writer.put_many(writer, [message("a", "topic_a")])
    assert :ok = Stream.Writer.put_many(writer, [message("b", "topic_b")])

    capture_log(fn ->
      assert :ok = Stream.Writer.put_many(writer, [message("c", "topic_a")])
    end)

    # topic_a вытеснен вторым топиком и объявлен заново третьей пачкой.
    assert Log.count(:declare) == 3
    assert Log.count(:delete_producer) == 2
  end

  # Подтверждение уходит в exit: кеш producer'а при этом не снимается — соединение
  # чистит его веткой `:DOWN`, а пересоздание на каждой пачке ничего не чинит.
  defmodule ExitConfirmConn do
    @moduledoc false

    def start_link(_opts), do: Agent.start_link(fn -> false end, name: __MODULE__)

    def connect, do: :ok

    def create_stream(_topic), do: :ok

    def declare_producer(topic, _ref) do
      Log.add({:declare, topic})
      {:ok, 7}
    end

    def publish(_producer_id, _publishing_id, _binary) do
      Agent.update(__MODULE__, fn _ -> true end)
      :ok
    end

    def producer_sequence(_topic, _ref) do
      if Agent.get(__MODULE__, & &1),
        do: exit({:timeout, {GenServer, :call, [__MODULE__, :producer_sequence]}}),
        else: {:ok, 0}
    end

    def delete_producer(producer_id) do
      Log.add({:delete_producer, producer_id})
      :ok
    end
  end

  test "exit при подтверждении не снимает producer" do
    start_supervised!(%{id: ExitConfirmConn, start: {ExitConfirmConn, :start_link, [[]]}})

    writer =
      start_supervised!(
        {Stream.Writer,
         connection: ExitConfirmConn, reference_prefix: "test-writer", confirm_timeout_ms: 50, confirm_poll_ms: 5}
      )

    capture_log(fn ->
      assert {:error, 0, %Error{code: :publish_unconfirmed}} =
               Stream.Writer.put_many(writer, [message("a")])

      assert {:error, 0, %Error{code: :publish_unconfirmed}} =
               Stream.Writer.put_many(writer, [message("b")])
    end)

    assert Log.count(:declare) == 1
    assert Log.count(:delete_producer) == 0
  end

  test "пачка из нескольких топиков при тесном кеше подтверждается целиком" do
    start_supervised!(%{id: FakeConn, start: {FakeConn, :start_link, [[confirm?: true]]}})

    writer =
      start_supervised!(
        {Stream.Writer,
         connection: FakeConn,
         reference_prefix: "test-writer",
         confirm_timeout_ms: 50,
         confirm_poll_ms: 5,
         max_producers: 1}
      )

    # Вытеснение идёт на границе пачки: сними оно producer topic_a по ходу — подтверждать
    # эту публикацию было бы нечем.
    assert :ok =
             Stream.Writer.put_many(writer, [message("a", "topic_a"), message("b", "topic_b")])

    assert Log.count(:declare) == 2
    assert Log.count(:delete_producer) == 1
  end

  test "мусор в опциях — ArgumentError на старте" do
    Process.flag(:trap_exit, true)

    capture_log(fn ->
      assert {:error, {%ArgumentError{message: message}, _stack}} =
               Stream.Writer.start_link(connection: FakeConn, reference_prefix: 42)

      assert message =~ "Core.Mq.Stream.Writer.init/1: invalid value for :reference_prefix option"

      assert {:error, {%ArgumentError{message: message}, _stack}} =
               Stream.Writer.start_link(connection: FakeConn, reference_prefix: "")

      assert message =~ ~s(invalid value for :reference_prefix option: ожидается непустая строка, получено "")

      assert {:error, {%ArgumentError{}, _stack}} =
               Stream.Writer.start_link(
                 connection: FakeConn,
                 reference_prefix: "test-writer",
                 confirm_timeout_ms: 0
               )

      assert {:error, {%ArgumentError{message: message}, _stack}} =
               Stream.Writer.start_link(connection: FakeConn, reference_prefix: "test-writer", max_producer: 8)

      assert message =~ "Core.Mq.Stream.Writer.init/1: unknown options [:max_producer]"
    end)
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
      {Stream.Writer, connection: conn, reference_prefix: "test-writer", confirm_timeout_ms: 50, confirm_poll_ms: 5}
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

  defp message(body, topic \\ "writer_test") do
    {:ok, message} = Message.new(Mq.Topic.new!(topic), %{}, body, Mq.Key.new!("agg-1"))
    message
  end
end
