defmodule Core.PubSub.MqSubscriberReliable.SupervisorTest do
  # Уровень логов модуля дерева — глобальное состояние Logger.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Core.Error
  alias Core.Mq
  alias Core.Mq.Message
  alias Core.MqFake
  alias Core.PubSub.MqSubscriberReliable

  require Error

  @tree __MODULE__.Tree
  @dlq __MODULE__.Dlq
  @products_reader __MODULE__.ProductsReader
  @products_sub __MODULE__.ProductsSubscriber
  @orders_reader __MODULE__.OrdersReader
  @orders_sub __MODULE__.OrdersSubscriber

  describe "старт" do
    test "DLQ-writer → на каждый топик читатель и его подписчик, rest_for_one; info «запущен»" do
      log = capture_info(fn -> start_tree!(tree_opts()) end)

      assert log =~
               "супервизор подписчиков: запущен: subscribers=#{inspect(@products_sub)},#{inspect(@orders_sub)}"

      assert start_order() == [@dlq, @products_reader, @products_sub, @orders_reader, @orders_sub]
    end

    test "rest_for_one: падение читателя перезапускает его подписчика и всех, кто стартовал позже" do
      start_tree!(tree_opts())
      before = pids()

      ref = Process.monitor(before[@products_reader])
      Process.exit(before[@products_reader], :kill)
      assert_receive {:DOWN, ^ref, :process, _pid, :killed}

      after_restart = await_restart(before)

      assert after_restart[@dlq] == before[@dlq]

      for name <- [@products_reader, @products_sub, @orders_reader, @orders_sub],
          do: assert(after_restart[name] != before[name])
    end

    test "без dlq_writer: — только читатели и подписчики" do
      start_tree!(Keyword.delete(tree_opts(), :dlq_writer))

      assert start_order() == [@products_reader, @products_sub, @orders_reader, @orders_sub]
    end

    test "подписчик подписан при старте, отравленное сообщение уходит в DLQ" do
      poison = message("products", "яд")
      start_tree!(tree_opts(products: [poison]))

      capture_log(fn ->
        assert :error = MqSubscriberReliable.run_once(@products_sub)
        assert :dlq = MqSubscriberReliable.run_once(@products_sub)
      end)

      assert [dead] = MqFake.Writer.published(@dlq)
      assert dead.body == "яд"
      assert Mq.Topic.value(dead.topic) == "products.dlq"
      assert MqFake.QueueReader.pending(@products_reader) == 0
      assert :idle = MqSubscriberReliable.run_once(@orders_sub)
    end

    test "enabled: false — :ignore, info «отключён», процессов нет" do
      log =
        capture_info(fn ->
          assert :ignore = MqSubscriberReliable.Supervisor.start_link(Keyword.put(tree_opts(), :enabled, false))
        end)

      assert log =~ "супервизор подписчиков: отключён: subscribers=#{inspect(@products_sub)}"
      assert Process.whereis(@products_sub) == nil
      assert Process.whereis(@dlq) == nil
    end

    test "topics: [] — :ignore, info «пропущен: нет топиков»" do
      log =
        capture_info(fn -> assert :ignore = MqSubscriberReliable.Supervisor.start_link(enabled: true, topics: []) end)

      assert log =~ "супервизор подписчиков: пропущен: нет топиков"
    end

    test "child_spec: id — name: дерева, по умолчанию модуль" do
      assert %{id: MqSubscriberReliable.Supervisor, type: :supervisor} =
               MqSubscriberReliable.Supervisor.child_spec(enabled: true, topics: [])

      assert %{id: :other_tree} =
               MqSubscriberReliable.Supervisor.child_spec(enabled: true, topics: [], name: :other_tree)
    end
  end

  describe "опции" do
    test "проверяются при любом enabled:" do
      for enabled <- [true, false] do
        assert_raise ArgumentError, ~r/нет обязательной опции :topics/, fn ->
          MqSubscriberReliable.Supervisor.start_link(enabled: enabled)
        end
      end
    end

    test "неизвестная опция и опция, которую задаёт дерево, — ArgumentError" do
      assert_raise ArgumentError, ~r/неизвестные опции \[:dlq\]/, fn ->
        MqSubscriberReliable.Supervisor.start_link(Keyword.put(tree_opts(), :dlq, @dlq))
      end

      for key <- ~w(reader_module reader dlq_writer dlq_handle subscribe)a do
        opts = tree_opts(subscriber: [{key, :x}])

        assert_raise ArgumentError, ~r/опция :subscriber — ожидается .*без #{inspect(key)}/, fn ->
          MqSubscriberReliable.Supervisor.start_link(opts)
        end
      end
    end

    test "процесс брокера без name: и подписчик без name: или topic: — ArgumentError" do
      assert_raise ArgumentError, ~r/опция :dlq_writer — ожидается \{модуль, опции с name: атомом\}/, fn ->
        MqSubscriberReliable.Supervisor.start_link(Keyword.put(tree_opts(), :dlq_writer, {MqFake.Writer, []}))
      end

      assert_raise ArgumentError, ~r/опция :reader — ожидается \{модуль, опции с name: атомом\}/, fn ->
        MqSubscriberReliable.Supervisor.start_link(
          enabled: true,
          topics: [[reader: MqFake.QueueReader, subscriber: []]]
        )
      end

      for key <- ~w(name topic)a do
        [topic | _] = Keyword.fetch!(tree_opts(), :topics)
        topic = Keyword.update!(topic, :subscriber, &Keyword.delete(&1, key))

        assert_raise ArgumentError, ~r/нет обязательной опции #{inspect(key)}/, fn ->
          MqSubscriberReliable.Supervisor.start_link(enabled: true, topics: [topic])
        end
      end
    end
  end

  describe "watch_list/1" do
    test "совпадает с именами запущенных процессов" do
      opts = tree_opts()
      start_tree!(opts)

      running =
        @tree
        |> Supervisor.which_children()
        |> Enum.map(fn {_id, pid, _type, _modules} -> registered_name(pid) end)

      assert Enum.map(MqSubscriberReliable.Supervisor.watch_list(opts), & &1.name) == Enum.reverse(running)

      assert MqSubscriberReliable.Supervisor.watch_list(opts) == [
               %{component: "mq_dlq_writer:#{inspect(@dlq)}", name: @dlq},
               %{component: "mq_reader:#{inspect(@products_reader)}", name: @products_reader},
               %{component: "mq_subscriber:#{inspect(@products_sub)}", name: @products_sub},
               %{component: "mq_reader:#{inspect(@orders_reader)}", name: @orders_reader},
               %{component: "mq_subscriber:#{inspect(@orders_sub)}", name: @orders_sub}
             ]
    end

    test "дерево не стартует — пусто: enabled: false, topics: [] при заданном dlq_writer:" do
      assert MqSubscriberReliable.Supervisor.watch_list(Keyword.put(tree_opts(), :enabled, false)) == []
      assert MqSubscriberReliable.Supervisor.watch_list(Keyword.put(tree_opts(), :topics, [])) == []
    end
  end

  # ---

  defp tree_opts(overrides \\ []) do
    on = fn _message, _data, _context ->
      {:error, Error.app(__MODULE__, code: :poison, ns: :pubsub, message: "яд")}
    end

    subscriber = [from_message: &{:ok, &1}, on_message: on, poll_interval_ms: 60_000, max_attempts: 2]

    [
      enabled: true,
      name: @tree,
      dlq_writer: {MqFake.Writer, name: @dlq},
      topics: [
        [
          reader: {MqFake.QueueReader, name: @products_reader, messages: Keyword.get(overrides, :products, [])},
          subscriber: [name: @products_sub, topic: "products"] ++ subscriber ++ Keyword.get(overrides, :subscriber, [])
        ],
        [
          reader: {MqFake.QueueReader, name: @orders_reader},
          subscriber: [name: @orders_sub, topic: "orders"] ++ subscriber
        ]
      ]
    ]
  end

  defp start_tree!(opts) do
    {:ok, pid} = start_supervised({MqSubscriberReliable.Supervisor, opts})
    pid
  end

  defp start_order do
    @tree
    |> Supervisor.which_children()
    |> Enum.map(&elem(&1, 0))
    |> Enum.reverse()
  end

  defp registered_name(pid) do
    {:registered_name, name} = Process.info(pid, :registered_name)
    name
  end

  defp pids, do: Map.new(Supervisor.which_children(@tree), fn {id, pid, _type, _modules} -> {id, pid} end)

  defp await_restart(before) do
    current = pids()

    if Enum.all?(current, fn {_id, pid} -> is_pid(pid) and pid != before[@products_reader] end) and
         current[@orders_sub] != before[@orders_sub],
       do: current,
       else: await_restart(before)
  end

  defp message(topic, body) do
    {:ok, message} = Message.new(Mq.Topic.new!(topic), %{"name" => "product_created"}, body, Mq.Key.new!("agg-1"))
    message
  end

  defp capture_info(fun) do
    Logger.put_module_level(MqSubscriberReliable.Supervisor, :info)

    try do
      capture_log(fun)
    after
      Logger.delete_module_level(MqSubscriberReliable.Supervisor)
    end
  end
end
