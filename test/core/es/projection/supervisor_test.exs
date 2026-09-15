defmodule Core.Es.Projection.SupervisorTest do
  # Дерево — синглтон ноды (имя Registry), читатели пишут в shared sandbox теста.
  use Core.DataCase, async: false

  import Core.EsAggregateRepoContract, only: [close: 0, dump: 1, open: 1, write!: 3]
  import ExUnit.CaptureLog

  alias Core.Config
  alias Core.Es
  alias Core.EsFixture
  alias Core.EsFixture.Account
  alias Core.Telemetry

  require Config

  @projection EsFixture.Projection
  @account_repo Config.repo!(Account.Repo)
  @quiet [
    idle_min_ms: 60_000,
    poll_interval_ms: 60_000,
    retry_min_ms: 60_000,
    retry_max_ms: 60_000
  ]

  defmodule Plain do
    @moduledoc false
  end

  defmodule Twin do
    @moduledoc false

    use Core.Es.Projection,
      name: "es_fixture",
      events: [Core.EsFixture.Account.Event.Opened]

    @impl true
    def project(_event), do: :ok

    @impl true
    def clear, do: :ok
  end

  defmodule Exiting do
    @moduledoc false

    use Core.Es.Projection,
      name: "reader_exiting",
      events: [Core.EsFixture.Account.Event.Opened]

    @impl true
    def project(_event), do: exit(:boom)

    @impl true
    def clear, do: :ok
  end

  defmodule Throwing do
    @moduledoc false

    use Core.Es.Projection,
      name: "reader_throwing",
      events: [Core.EsFixture.Account.Event.Opened]

    @impl true
    def project(_event), do: throw(:boom)

    @impl true
    def clear, do: :ok
  end

  defmodule Raising do
    @moduledoc false

    use Core.Es.Projection,
      name: "reader_raising",
      events: [Core.EsFixture.Account.Event.Opened]

    @impl true
    def project(_event), do: raise(ArgumentError, "колбэк сломан")

    @impl true
    def clear, do: :ok
  end

  defmodule DownRepo do
    @moduledoc false

    def in_transaction?, do: false

    def transact(_fun, _opts), do: raise(DBConnection.ConnectionError, "соединение недоступно")
  end

  defmodule Unreachable do
    @moduledoc false

    use Core.Es.Projection,
      name: "reader_unreachable",
      events: [Core.EsFixture.Account.Event.Opened],
      repo: Core.Es.Projection.SupervisorTest.DownRepo

    @impl true
    def project(_event), do: :ok

    @impl true
    def clear, do: :ok
  end

  defmodule MirrorRepo do
    @moduledoc false

    # Второй repo проекций: слушатель берёт его конфигурацию, пачек при интервалах @quiet нет.
    defdelegate config, to: Core.TestRepo
  end

  defmodule Mirrored do
    @moduledoc false

    use Core.Es.Projection,
      name: "reader_mirrored",
      events: [Core.EsFixture.Account.Event.Opened],
      repo: Core.Es.Projection.SupervisorTest.MirrorRepo

    @impl true
    def project(_event), do: :ok

    @impl true
    def clear, do: :ok
  end

  defmodule Blocking do
    @moduledoc false

    use Core.Es.Projection,
      name: "reader_blocking",
      events: [Core.EsFixture.Account.Event.Opened]

    # Пачка стоит на событии, пока тест её не отпустит.
    @impl true
    def project(_event) do
      send(:reader_blocking_test, {:projecting, self()})

      receive do
        :release -> :ok
      end
    end

    @impl true
    def clear, do: :ok
  end

  setup do
    handler_id = "es-projection-cycle-#{inspect(self())}"

    :ok =
      :telemetry.attach(
        handler_id,
        Telemetry.event([:es, :projection, :cycle]),
        fn _event, measurements, metadata, test_pid ->
          send(test_pid, {:cycle, metadata, measurements})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    # Отметка дерева — глобальное состояние ноды.
    on_exit(fn -> :persistent_term.erase(Es.Projection.Supervisor.Mark) end)
  end

  describe "старт" do
    test "Registry → читатели под именами модулей проекций; первый тик — таймер idle_min_ms" do
      log = capture_info(fn -> start_tree!([@projection, Exiting]) end)

      assert log =~ "супервизор проекций: запущен: projections=es_fixture,reader_exiting"

      reader = Process.whereis(@projection)
      assert [{^reader, nil}] = Registry.lookup(Es.Projection.Registry, {:written, "fixture"})

      assert Enum.sort(Registry.lookup(Es.Projection.Registry, {:written, "account"})) ==
               Enum.sort([{reader, nil}, {Process.whereis(Exiting), nil}])

      state = :sys.get_state(reader)
      assert Process.read_timer(state.timer_ref) in 50_000..60_000
      assert checkpoint!() == nil

      assert %{projections: [@projection, Exiting], enabled: true, batch_size: 100} =
               Es.Projection.Supervisor.Mark.find()
    end

    test "enabled: false — :ignore, info и отметка" do
      log =
        capture_info(fn ->
          assert :ignore =
                   Es.Projection.Supervisor.start_link(projections: [@projection], enabled: false)
        end)

      assert log =~ "супервизор проекций: отключён: projections=es_fixture"
      assert Process.whereis(Es.Projection.Registry) == nil

      assert %{
               projections: [@projection],
               enabled: false,
               shutdown: 30_000,
               await: :poll,
               await_min_ms: 10,
               await_max_ms: 100,
               notifications: true
             } = Es.Projection.Supervisor.Mark.find()
    end

    test "await_min_ms: и await_max_ms: — в отметке" do
      capture_info(fn ->
        assert :ignore =
                 Es.Projection.Supervisor.start_link(
                   projections: [@projection],
                   enabled: false,
                   await_min_ms: 25,
                   await_max_ms: 250
                 )
      end)

      assert %{await_min_ms: 25, await_max_ms: 250} = Es.Projection.Supervisor.Mark.find()
    end

    test "notifications: false и keyword опций соединения — в отметке" do
      for notifications <- [false, [hostname: "db-direct"]] do
        capture_info(fn ->
          assert :ignore =
                   Es.Projection.Supervisor.start_link(
                     projections: [@projection],
                     enabled: false,
                     notifications: notifications
                   )
        end)

        assert %{notifications: ^notifications} = Es.Projection.Supervisor.Mark.find()
      end
    end

    test "projections: [] — :ignore, info «пропущен: нет проекций» и отметка" do
      log =
        capture_info(fn ->
          assert :ignore = Es.Projection.Supervisor.start_link(projections: [], enabled: true)
        end)

      assert log =~ "супервизор проекций: пропущен: нет проекций"
      assert Process.whereis(Es.Projection.Registry) == nil
      assert %{projections: [], enabled: true} = Es.Projection.Supervisor.Mark.find()
    end

    test "опции — ArgumentError при любом enabled:" do
      assert_raise ArgumentError, ~r/нет обязательной опции :projections/, fn ->
        Es.Projection.Supervisor.start_link(enabled: true)
      end

      assert_raise ArgumentError, ~r/нет обязательной опции :enabled/, fn ->
        Es.Projection.Supervisor.start_link(projections: [@projection])
      end

      assert_raise ArgumentError,
                   ~r/:projections — ожидается модуль use Core.Es.Projection/,
                   fn ->
                     Es.Projection.Supervisor.start_link(projections: [Plain], enabled: false)
                   end

      assert_raise ArgumentError, ~r/name: "es_fixture" у нескольких проекций/, fn ->
        Es.Projection.Supervisor.start_link(projections: [@projection, Twin], enabled: false)
      end

      assert_raise ArgumentError,
                   ~r/:batch_size — ожидается положительное целое, получено 0/,
                   fn ->
                     Es.Projection.Supervisor.start_link(
                       projections: [],
                       enabled: false,
                       batch_size: 0
                     )
                   end

      assert_raise ArgumentError,
                   ~r/:await_min_ms — ожидается положительное целое, получено 0/,
                   fn ->
                     Es.Projection.Supervisor.start_link(
                       projections: [],
                       enabled: true,
                       await_min_ms: 0
                     )
                   end

      assert_raise ArgumentError,
                   ~r/:await_max_ms — ожидается положительное целое, получено -1/,
                   fn ->
                     Es.Projection.Supervisor.start_link(
                       projections: [],
                       enabled: false,
                       await_max_ms: -1
                     )
                   end

      assert_raise ArgumentError,
                   ~r/:await — ожидается одно из \[:poll, :inline\], получено :sync/,
                   fn ->
                     Es.Projection.Supervisor.start_link(
                       projections: [],
                       enabled: false,
                       await: :sync
                     )
                   end

      assert_raise ArgumentError, ~r/await: :inline — только при enabled: false/, fn ->
        Es.Projection.Supervisor.start_link(projections: [], enabled: true, await: :inline)
      end

      assert_raise ArgumentError,
                   ~r/:notifications — ожидается true, false или keyword, получено :yes/,
                   fn ->
                     Es.Projection.Supervisor.start_link(
                       projections: [],
                       enabled: true,
                       notifications: :yes
                     )
                   end

      assert_raise ArgumentError,
                   ~r/:notifications — ожидается .*, получено \["db-direct"\]/,
                   fn ->
                     Es.Projection.Supervisor.start_link(
                       projections: [],
                       enabled: false,
                       notifications: ["db-direct"]
                     )
                   end
    end

    test "слушатели — последними, по одному на различный repo: проекций; notifications: false — без них" do
      tree = start_tree!([@projection, Exiting, Mirrored])

      assert child_ids(tree) == [:listeners, :readers, Es.Projection.Registry]

      assert listeners(tree) ==
               Enum.sort([
                 {Es.Projection.Listener, TestRepo},
                 {Es.Projection.Listener, MirrorRepo}
               ])

      :ok = stop_supervised(Es.Projection.Supervisor)
      tree = start_tree!([@projection, Mirrored], notifications: false)

      assert child_ids(tree) == [:readers, Es.Projection.Registry]
      assert %{notifications: false} = Es.Projection.Supervisor.Mark.find()
    end

    test "второй супервизор на ноде — отказ старта по имени Registry, отметка первого" do
      start_tree!([@projection])

      assert {:error, reason} =
               start_supervised(
                 {Es.Projection.Supervisor, [projections: [Exiting], enabled: true]},
                 id: :second
               )

      assert inspect(reason) =~ "already_started"
      assert %{projections: [@projection]} = Es.Projection.Supervisor.Mark.find()
    end

    test "Registry не запущен — wake, wake_projection и signal_checkpoint отдают :ok" do
      assert :ok = Es.Projection.Registry.wake("account")
      assert :ok = Es.Projection.Registry.wake_projection("es_fixture")
      assert :ok = Es.Projection.Registry.signal_checkpoint("es_fixture")
    end
  end

  describe "цикл" do
    test "тик: старт с начала, пачка событий, холостая — удвоение от idle_min_ms" do
      for _ <- 1..2, do: write!(@account_repo, Account.ID.new(), [open("Счёт")])
      start_tree!([@projection], idle_min_ms: 10_000)

      tick(@projection)

      assert_receive {:cycle, %{projection: "es_fixture", result: :processed},
                      %{events: 0, attempt: 0}}

      assert_receive {:cycle, %{projection: "es_fixture", result: :processed}, %{events: 2}}
      assert_receive {:cycle, %{projection: "es_fixture", result: :idle}, %{events: 0}}

      assert length(rows()) == 2
      assert %{result: :idle, backoff: %{idle_ms: 20_000}} = :sys.get_state(reader(@projection))
    end

    test "wake в ожидании — цикл сразу без сброса счётчика; wake после commit append и по имени проекции" do
      start_tree!([@projection], idle_min_ms: 10_000)
      tick(@projection)
      assert_receive {:cycle, %{result: :processed}, %{events: 0}}
      assert_receive {:cycle, %{result: :idle}, _measurements}

      wake("account")
      assert_receive {:cycle, %{result: :idle}, _measurements}
      assert %{backoff: %{idle_ms: 40_000}} = :sys.get_state(reader(@projection))

      write!(@account_repo, Account.ID.new(), [open("Счёт")])
      assert_receive {:cycle, %{result: :processed}, %{events: 1}}
      assert_receive {:cycle, %{result: :idle}, _measurements}
      assert length(rows()) == 1

      wake("unknown")
      refute_receive {:cycle, _metadata, _measurements}, 100

      # Тип агрегата и имя проекции — разные ключи, даже совпав строкой.
      wake("es_fixture")
      :ok = Es.Projection.Registry.wake_projection("account")
      refute_receive {:cycle, _metadata, _measurements}, 100

      :ok = Es.Projection.Registry.wake_projection("es_fixture")
      assert_receive {:cycle, %{result: :idle}, _measurements}
      assert %{backoff: %{idle_ms: 40_000}} = :sys.get_state(reader(@projection))
    end

    test "отказ project/1 — повтор с warning, wake не ускоряет, рестарта нет; починка — дальше" do
      account = Account.ID.new()
      write!(@account_repo, account, [open("Счёт")])
      start_tree!([@projection])
      reader = reader(@projection)
      tick(@projection)
      assert_receive {:cycle, %{result: :processed}, %{events: 0}}
      assert_receive {:cycle, %{result: :processed}, %{events: 1}}
      assert_receive {:cycle, %{result: :idle}, _measurements}
      TestRepo.delete_all(EsFixture.Projection.Row)
      %{xid: xid, number: number} = checkpoint!()

      log =
        capture_log(fn ->
          write!(@account_repo, account, [close()])

          assert_receive {:cycle,
                          %{
                            projection: "es_fixture",
                            result: :retry,
                            error: "es_fixture/stream_not_found"
                          }, %{events: 0, attempt: 1}}

          wake("account")
          refute_receive {:cycle, _metadata, _measurements}, 100

          tick(@projection)
          assert_receive {:cycle, %{result: :retry}, %{attempt: 2}}
        end)

      assert log =~
               "проекция: отказ пачки, повтор: projection=es_fixture position=#{xid}/#{number} " <>
                 "event_id=#{last_event_id!(account)} attempt=1"

      assert log =~ "attempt=2"
      assert reader(@projection) == reader

      assert %{attempt: 2, error: "es_fixture/stream_not_found", retry_since: %DateTime{}} =
               :sys.get_state(reader)

      insert_row!(account)
      tick(@projection)
      assert_receive {:cycle, %{result: :processed}, %{attempt: 0}}
      assert_receive {:cycle, %{result: :idle}, _measurements}
      assert %{attempt: 0, error: nil, retry_since: nil} = :sys.get_state(reader)
    end

    test "исключение в колбэке и вне его, exit и throw — повтор с модулем исключения, exit, throw" do
      write!(@account_repo, Account.ID.new(), [open("Счёт")])
      projections = [Raising, Exiting, Throwing, Unreachable]

      # У DownRepo нет конфигурации соединения для слушателя.
      start_tree!(projections, notifications: false)

      log =
        capture_log(fn ->
          Enum.each(projections, &tick/1)

          assert_receive {:cycle,
                          %{projection: "reader_raising", result: :retry, error: "ArgumentError"},
                          %{attempt: 1}}

          assert_receive {:cycle,
                          %{
                            projection: "reader_unreachable",
                            result: :retry,
                            error: "DBConnection.ConnectionError"
                          }, %{attempt: 1}}

          assert_receive {:cycle, %{projection: "reader_exiting", result: :retry, error: "exit"},
                          %{attempt: 1}}

          assert_receive {:cycle,
                          %{projection: "reader_throwing", result: :retry, error: "throw"},
                          %{attempt: 1}}
        end)

      assert log =~
               "projection=reader_unreachable position=nil event_id=nil attempt=1 " <>
                 "причина=соединение недоступно"

      # exit и throw минуют отказ пачки: позиции и события у читателя нет
      assert log =~ "projection=reader_exiting position=nil event_id=nil attempt=1 причина=:boom"
      assert log =~ "projection=reader_throwing position=nil event_id=nil attempt=1 причина=:boom"

      for projection <- projections do
        assert %{attempt: 1} = :sys.get_state(reader(projection))
      end
    end

    test "чекпоинт новее version: — :outdated через poll_interval_ms, warning один раз" do
      write!(@account_repo, Account.ID.new(), [open("Счёт")])
      :ok = insert_checkpoint!("es_fixture", 2)
      start_tree!([@projection], poll_interval_ms: 50_000)

      log =
        capture_log(fn ->
          tick(@projection)
          assert_receive {:cycle, %{result: :outdated}, %{events: 0, attempt: 0}}
          tick(@projection)
          assert_receive {:cycle, %{result: :outdated}, _measurements}

          wake("account")
          refute_receive {:cycle, _metadata, _measurements}, 100
        end)

      assert [_before, _after] = String.split(log, "чекпоинт новее версии кода")
      assert log =~ "projection=es_fixture version=1"
      assert rows() == []

      state = :sys.get_state(reader(@projection))
      assert Process.read_timer(state.timer_ref) in 40_000..50_000
    end
  end

  describe "остановка" do
    test "trap_exit: остановка посреди пачки ждёт её конца, terminate/2 только логирует" do
      write!(@account_repo, Account.ID.new(), [open("Счёт")])
      Process.register(self(), :reader_blocking_test)
      start_tree!([Blocking])
      reader = reader(Blocking)
      tick(Blocking)
      assert_receive {:cycle, %{projection: "reader_blocking", result: :processed}, %{events: 0}}
      assert_receive {:projecting, ^reader}

      release_on_shutdown(reader)

      log = capture_info(fn -> assert :ok = stop_supervised(Es.Projection.Supervisor) end)

      assert_received {:cycle, %{projection: "reader_blocking", result: :processed}, %{events: 1}}
      assert log =~ "проекция: читатель остановлен: projection=reader_blocking reason=:shutdown"
      assert %{xid: xid} = checkpoint!("reader_blocking")
      assert is_integer(xid)
    end
  end

  describe "watch_list/1" do
    test "элемент на читателя под именем модуля проекции; enabled: false — пусто" do
      assert Es.Projection.Supervisor.watch_list(
               projections: [@projection, Exiting],
               enabled: true
             ) ==
               [
                 %{component: "es_projection:es_fixture", name: @projection},
                 %{component: "es_projection:reader_exiting", name: Exiting}
               ]

      assert Es.Projection.Supervisor.watch_list(projections: [@projection], enabled: false) == []
    end
  end

  defp start_tree!(projections, opts \\ []) do
    opts = Keyword.merge([projections: projections, enabled: true] ++ @quiet, opts)
    {:ok, pid} = start_supervised({Es.Projection.Supervisor, opts})
    pid
  end

  defp child_ids(tree), do: Enum.map(Supervisor.which_children(tree), &elem(&1, 0))

  defp listeners(tree) do
    {:listeners, pid, :supervisor, _modules} =
      List.keyfind(Supervisor.which_children(tree), :listeners, 0)

    pid
    |> Supervisor.which_children()
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  defp reader(projection), do: Process.whereis(projection)

  defp tick(projection), do: send(reader(projection), :tick)

  defp wake(type), do: :ok = Es.Projection.Registry.wake(type)

  # Отпустить пачку, когда сигнал остановки дошёл до читателя: трассировка приёма, без опроса.
  defp release_on_shutdown(reader) do
    helper =
      spawn_link(fn ->
        receive do
          {:trace, ^reader, :receive, {:EXIT, _parent, :shutdown}} -> send(reader, :release)
        end
      end)

    1 = :erlang.trace(reader, true, [:receive, {:tracer, helper}])
    :ok
  end

  # Уровень логов тестов — `:warning`: `info` дерева виден только с уровнем его модулей.
  defp capture_info(fun) do
    modules = [Es.Projection.Supervisor, Es.Projection.Reader]
    Enum.each(modules, &Logger.put_module_level(&1, :info))

    try do
      capture_log(fun)
    after
      Enum.each(modules, &Logger.delete_module_level/1)
    end
  end

  defp rows, do: TestRepo.all(EsFixture.Projection.Row)

  defp insert_row!(account) do
    row = %{aggregate_type: "account", aggregate_id: dump(account), name: "Счёт", closed: false}
    {1, nil} = TestRepo.insert_all(EsFixture.Projection.Row, [row])
    :ok
  end

  defp last_event_id!(account) do
    sql =
      "SELECT event_id FROM es_events WHERE aggregate_id = $1 ORDER BY aggregate_version DESC LIMIT 1"

    %{rows: [[event_id]]} = TestRepo.query!(sql, [Ecto.UUID.dump!(dump(account))])
    Ecto.UUID.load!(event_id)
  end

  defp checkpoint!(name \\ "es_fixture") do
    sql = "SELECT xid, number, version FROM es_checkpoints WHERE name = $1"

    case TestRepo.query!(sql, [name]).rows do
      [] -> nil
      [[xid, number, version]] -> %{xid: xid, number: number, version: version}
    end
  end

  defp insert_checkpoint!(name, version) do
    sql = "INSERT INTO es_checkpoints (name, version) VALUES ($1, $2)"
    %Postgrex.Result{num_rows: 1} = TestRepo.query!(sql, [name, version])
    :ok
  end
end
