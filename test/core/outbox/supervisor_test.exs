defmodule Core.Outbox.SupervisorTest do
  # Отметка дерева в `:persistent_term`, имя супервизора и уровень логов модуля — глобальное состояние.
  use Core.DataCase, async: false

  import ExUnit.CaptureLog

  alias Core.Context
  alias Core.Mq
  alias Core.MqFake
  alias Core.Outbox
  alias Core.Outbox.Cleaner
  alias Core.Outbox.Record
  alias Core.Outbox.Supervisor.Mark

  @repo Core.Config.outbox_repo()
  @tree Core.Outbox.Supervisor
  @connection __MODULE__.Connection
  @orders_writer __MODULE__.OrdersWriter
  @orders_poller __MODULE__.OrdersPoller
  @rest_writer __MODULE__.RestWriter
  @rest_poller __MODULE__.RestPoller

  setup do
    handler_id = "outbox-supervisor-#{inspect(self())}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:core, :outbox, :poller, :cycle],
        fn event, measurements, metadata, test_pid -> send(test_pid, {:telemetry, event, measurements, metadata}) end,
        self()
      )

    on_exit(fn ->
      :telemetry.detach(handler_id)
      :persistent_term.erase(Mark)
    end)

    start_supervised!({MqFake.Writer, name: @rest_writer})
    {:ok, context: Context.new()}
  end

  describe "старт" do
    test "соединение → writer и поллер по элементам → cleaner, rest_for_one; info «запущен»" do
      log = capture_info(fn -> start_tree!(tree_opts()) end)

      assert log =~ "супервизор очереди outbox: запущен: pollers=#{inspect(@orders_poller)},#{inspect(@rest_poller)}"
      assert start_order() == [@connection, @orders_writer, @orders_poller, @rest_poller, Cleaner]
    end

    test "rest_for_one: падение writer'а перезапускает его поллер и всё, что стартовало позже" do
      start_tree!(tree_opts())
      before = pids()

      ref = Process.monitor(before[@orders_writer])
      Process.exit(before[@orders_writer], :kill)
      assert_receive {:DOWN, ^ref, :process, _pid, :killed}

      after_restart = await_restart(before)

      assert after_restart[@connection] == before[@connection]

      for id <- [@orders_writer, @orders_poller, @rest_poller, Cleaner],
          do: assert(after_restart[id] != before[id])
    end

    test "via: — ребёнка нет, поллер пишет через указанный процесс", %{context: context} do
      start_tree!(tree_opts())

      append!("payments", context)

      assert_receive {:telemetry, _, _, %{result: :processed}}, 1_000
      assert [message] = MqFake.Writer.published(@rest_writer)
      assert Mq.Topic.value(message.topic) == "payments"
      refute Map.has_key?(pids(), @rest_writer)
    end

    test "enabled: false — :ignore, info «отключён», процессов нет, wake — no-op", %{context: context} do
      Process.register(self(), @rest_poller)

      log =
        capture_info(fn -> assert :ignore = Core.Outbox.Supervisor.start_link(tree_opts(enabled: false)) end)

      assert log =~ "супервизор очереди outbox: отключён: pollers=#{inspect(@orders_poller)}"
      assert Process.whereis(@tree) == nil
      assert Process.whereis(Cleaner) == nil

      append!("payments", context)

      refute_receive :wake, 100
    end

    test "второе дерево на ноде не стартует и отметку работающего не трогает" do
      start_tree!(tree_opts())

      [orders, _rest] = pollers()

      assert {:error, {:already_started, _pid}} = Core.Outbox.Supervisor.start_link(tree_opts(pollers: [orders]))
      assert List.keymember?(Mark.pollers(), @rest_poller, 0)
    end
  end

  describe "проверки опций" do
    test "неизвестная опция — ArgumentError, и при enabled: false" do
      for enabled <- [true, false] do
        assert start_error(tree_opts(enabled: enabled, delivery_module: Outbox.Delivery.Mq)) =~
                 "Outbox.Supervisor: неизвестные опции [:delivery_module]"
      end
    end

    test "нет обязательной опции — ArgumentError" do
      for key <- ~w(
            enabled cluster_query repo pollers poll_interval_ms idle_min_ms batch_size lock_duration_seconds
            max_attempts published_ttl_seconds cleaner_interval_ms
          )a do
        assert start_error(Keyword.delete(tree_opts(), key)) =~
                 "Outbox.Supervisor: нет обязательной опции #{inspect(key)}"
      end
    end

    test "значение не той формы — ArgumentError с именем опции" do
      for {key, value, expected} <- [
            {:enabled, "true", "true или false"},
            {:cluster_query, 1, "строку, nil или :ignore"},
            {:allow_cluster, "true", "true или false"},
            {:batch_size, 0, "положительное целое"},
            {:batch_size, 10_000, "значение Core.Outbox.BatchSize"},
            {:lock_duration_seconds, "30", "положительное целое"},
            {:connection, {MqFake.Writer, []}, "{модуль, опции с name: атомом}"},
            {:context_factory, fn _ -> Context.new() end, "функция арности 0"}
          ] do
        assert start_error(tree_opts([{key, value}])) =~
                 "Outbox.Supervisor: опция #{inspect(key)} — ожидается #{expected}"
      end
    end

    test "оба или ни одного из writer: / via: — ArgumentError" do
      both = [name: @rest_poller, label: "rest", writer: {MqFake.Writer, name: @rest_writer}, via: {MqFake.Writer, :x}]
      none = [name: @rest_poller, label: "rest"]

      for poller <- [both, none] do
        assert start_error(tree_opts(pollers: [poller])) =~ "ожидается ровно один из writer: и via: у поллера"
      end
    end

    test "дубль name: или label: — ArgumentError" do
      [orders, rest] = pollers()

      assert start_error(tree_opts(pollers: [orders, Keyword.put(rest, :name, @orders_poller)])) =~
               "ожидается имена процессов без повторов"

      assert start_error(tree_opts(pollers: [orders, Keyword.put(rest, :label, "orders")])) =~
               "ожидается label: без повторов"
    end

    test "enabled: true при pollers: [] — ArgumentError" do
      assert start_error(tree_opts(pollers: [])) =~ "enabled: true при pollers: []"
    end
  end

  describe "проверки старта" do
    test "пересечение фильтров поллеров — ArgumentError с именами обоих" do
      [orders, rest] = pollers()
      message = start_error(tree_opts(pollers: [orders, Keyword.put(rest, :topics, :all)]))

      assert message =~ "фильтры топиков поллеров пересекаются"
      assert message =~ inspect(@orders_poller)
      assert message =~ inspect(@rest_poller)
    end

    test "пересечение ищется по всем парам, {:except, _} и покрывающий его {:only, _} совместимы" do
      [orders, rest] = pollers()
      third = [name: __MODULE__.Third, label: "third", topics: {:only, ["orders"]}, via: {MqFake.Writer, :x}]

      assert start_error(tree_opts(pollers: [orders, Keyword.put(rest, :topics, {:only, ["b"]}), third])) =~
               "фильтры топиков поллеров пересекаются"

      start_tree!(tree_opts())
    end

    test "включённая очередь в кластере без allow_cluster: true — ArgumentError с инструкцией" do
      for opts <- [[cluster_query: "app.internal"], [cluster_query: "app.internal", allow_cluster: false]] do
        message = start_error(tree_opts(opts))

        assert message =~ "app.internal"
        assert message =~ "OUTBOX_ENABLED"
        assert message =~ "allow_cluster: true"
      end
    end

    test "без кластеризации и в выключенной очереди — старт без warning" do
      for query <- [nil, :ignore, ""] do
        log = capture_log(fn -> start_tree!(tree_opts(cluster_query: query)) end)

        refute log =~ "порядок доставки"
        stop_supervised!(Core.Outbox.Supervisor)
      end

      log =
        capture_log(fn ->
          assert :ignore =
                   Core.Outbox.Supervisor.start_link(
                     tree_opts(enabled: false, cluster_query: "app.internal", allow_cluster: true)
                   )
        end)

      refute log =~ "порядок доставки"
    end

    test "allow_cluster: true в кластере — старт с warning" do
      log = capture_log(fn -> start_tree!(tree_opts(cluster_query: "app.internal", allow_cluster: true)) end)

      assert log =~ "[warning]"
      assert log =~ "порядок доставки между нодами не гарантирован"
      assert log =~ "cluster_query=\"app.internal\""
    end
  end

  describe "wake" do
    test "вставка будит только поллер, чей фильтр совпал с топиком", %{context: context} do
      start_tree!(tree_opts())
      rest = Process.whereis(@rest_poller)
      :erlang.trace(rest, true, [:receive])

      append!("orders", context)

      assert_receive {:telemetry, _, _, %{result: :processed}}, 1_000
      refute_receive {:trace, ^rest, :receive, :wake}, 200
      assert [_message] = MqFake.Writer.published(@orders_writer)
    end

    test "без дерева wake не будит никого — и при config :core, Core.Outbox, poller_name:", %{context: context} do
      previous = Application.get_env(:core, Outbox)
      Application.put_env(:core, Outbox, poller_name: @rest_poller)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:core, Outbox, previous),
          else: Application.delete_env(:core, Outbox)
      end)

      :persistent_term.erase(Mark)
      Process.register(self(), @rest_poller)

      append!("payments", context)

      refute_receive :wake, 100
    end
  end

  describe "watch_list/1" do
    test "соединение, writer только у writer:, поллеры, cleaner" do
      assert Core.Outbox.Supervisor.watch_list(tree_opts()) == [
               %{component: "outbox_connection", name: @connection},
               %{component: "outbox_writer:orders", name: @orders_writer},
               %{component: "outbox_poller:orders", name: @orders_poller},
               %{component: "outbox_poller:rest", name: @rest_poller},
               %{component: "outbox_cleaner", name: Cleaner}
             ]
    end

    test "без connection: — без элемента соединения; enabled: false — пусто" do
      refute Enum.any?(
               Core.Outbox.Supervisor.watch_list(Keyword.delete(tree_opts(), :connection)),
               &(&1.component == "outbox_connection")
             )

      assert Core.Outbox.Supervisor.watch_list(tree_opts(enabled: false)) == []
    end

    test "опции проверяются как в start_link/1" do
      assert_raise ArgumentError, ~r/нет обязательной опции :cluster_query/, fn ->
        Core.Outbox.Supervisor.watch_list(Keyword.delete(tree_opts(), :cluster_query))
      end
    end
  end

  defp tree_opts(overrides \\ []) do
    Keyword.merge(
      [
        enabled: true,
        cluster_query: nil,
        repo: @repo,
        connection: {MqFake.Writer, name: @connection},
        pollers: pollers(),
        poll_interval_ms: 60_000,
        idle_min_ms: 60_000,
        batch_size: 10,
        lock_duration_seconds: 30,
        max_attempts: 3,
        published_ttl_seconds: 60,
        cleaner_interval_ms: 86_400_000
      ],
      overrides
    )
  end

  defp pollers do
    [
      [
        name: @orders_poller,
        label: "orders",
        topics: {:only, ["orders"]},
        writer: {MqFake.Writer, name: @orders_writer}
      ],
      [name: @rest_poller, label: "rest", topics: {:except, ["orders"]}, via: {MqFake.Writer, @rest_writer}]
    ]
  end

  defp start_tree!(opts), do: start_supervised!({Core.Outbox.Supervisor, opts})

  defp start_error(opts) do
    %ArgumentError{message: message} = assert_raise(ArgumentError, fn -> Core.Outbox.Supervisor.start_link(opts) end)
    message
  end

  defp append!(topic, context) do
    {:ok, record} =
      Record.new(Outbox.Topic.new!(topic), Outbox.Key.new!("agg-1"), Outbox.Name.new!("created"), %{"n" => 1})

    :ok = @repo.append([record], context)
  end

  defp start_order do
    @tree
    |> Supervisor.which_children()
    |> Enum.map(&elem(&1, 0))
    |> Enum.reverse()
  end

  defp pids, do: Map.new(Supervisor.which_children(@tree), fn {id, pid, _type, _modules} -> {id, pid} end)

  defp await_restart(before) do
    current = pids()

    if Enum.all?(current, fn {_id, pid} -> is_pid(pid) end) and current[Cleaner] != before[Cleaner],
      do: current,
      else: await_restart(before)
  end

  defp capture_info(fun) do
    Logger.put_module_level(Core.Outbox.Supervisor, :info)

    try do
      capture_log(fun)
    after
      Logger.delete_module_level(Core.Outbox.Supervisor)
    end
  end
end
