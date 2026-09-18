defmodule Core.Es.Aggregate.ProcessTest do
  # Отметка старта процесса — глобальное состояние ноды, экспортёр span'ов — глобальный ресурс SDK.
  use Core.DataCase, async: false

  import Core.EsAggregateRepoContract,
    only: [check: 0, close: 0, dump: 1, freeze: 0, open: 1, rename: 1, stream_tags: 1, write!: 3]

  import ExUnit.CaptureLog

  alias Core.Context
  alias Core.Error
  alias Core.Es
  alias Core.EsFixture
  alias Core.EsFixture.Account
  alias Core.Helper.Transact
  alias Core.Otel
  alias Core.OtelFixture
  alias Core.Repo
  alias Core.Telemetry
  alias Core.Version

  require Error

  @logging [
    Es.Aggregate.Process,
    Es.Aggregate.Process.Server,
    Es.Transact
  ]

  defmodule Unstarted do
    @moduledoc false

    use Core.Es.Aggregate.Process,
      repo: Core.EsFixture.Account.Repo
  end

  defmodule Unknown do
    @moduledoc false

    defstruct ~w(at by)a
  end

  setup do
    handler_id = "es-aggregate-process-#{inspect(self())}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        Enum.map(~w(execute start stop)a, &Telemetry.event([:es, :aggregate, :process, &1])),
        fn event, measurements, metadata, test_pid ->
          case List.last(event) do
            :execute -> send(test_pid, {:execute, metadata, measurements})
            kind -> send(test_pid, {kind, metadata})
          end
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    on_exit(fn -> Enum.each([Account.Process, Account.RacyProcess, Account.KeyedProcess], &erase_mark/1) end)
  end

  describe "старт" do
    test "enabled: false — :ignore, info и отметка с опциями по умолчанию" do
      log = capture_at(:info, fn -> assert :ignore = start(Account.Process, enabled: false) end)

      assert log =~ "процесс агрегата: отключён: type=account"

      assert Es.Aggregate.Process.mark(Account.Process) ==
               %{enabled: false, retries: 3, idle_timeout: 60_000}

      assert Es.Aggregate.Process.mark(Account.RacyProcess) == nil
    end

    test "элемент дерева супервизии: {Agg.Process, opts}" do
      assert {:ok, :undefined} = start_supervised({Account.Process, enabled: false, retries: 1})
      assert %{retries: 1} = Es.Aggregate.Process.mark(Account.Process)
    end

    test "опции — ArgumentError без отметки" do
      assert_raise ArgumentError, ~r/нет обязательной опции :enabled/, fn ->
        start(Account.Process, [])
      end

      assert_raise ArgumentError, ~r/:enabled — ожидается true или false, получено "false"/, fn ->
        start(Account.Process, enabled: "false")
      end

      assert_raise ArgumentError, ~r/:retries — ожидается положительное целое, получено 0/, fn ->
        start(Account.Process, enabled: false, retries: 0)
      end

      assert_raise ArgumentError,
                   ~r/:idle_timeout — ожидается положительное целое, получено :infinity/,
                   fn -> start(Account.Process, enabled: false, idle_timeout: :infinity) end

      assert Es.Aggregate.Process.mark(Account.Process) == nil
    end
  end

  describe "процесс на id" do
    test "enabled: true — Supervisor из Registry и DynamicSupervisor под именем модуля, info и отметка" do
      log =
        capture_at(:info, fn ->
          assert {:ok, tree} = start_supervised({Account.Process, enabled: true})
          assert Process.whereis(Account.Process) == tree
        end)

      assert log =~ "процесс агрегата: запущен: type=account"

      assert Es.Aggregate.Process.mark(Account.Process) ==
               %{enabled: true, retries: 3, idle_timeout: 60_000}

      mods = for {_id, _pid, _type, [mod]} <- Supervisor.which_children(Account.Process), do: mod
      assert Enum.sort(mods) == [DynamicSupervisor, Registry]

      assert %{active: 0} = DynamicSupervisor.count_children(Account.Process.Supervisor)
    end

    test "первая команда стартует процесс лениво, дальше команды идут в нём: get_decision, затем refresh" do
      start_tree!(Account.Process)
      id = Account.ID.new()
      :ok = attach_load()

      log =
        capture_at(:debug, fn ->
          assert Account.Process.execute(id, :current, open("Счёт"), Context.new(), report(self())) ==
                   {:ok, Version.new!(1)}
        end)

      assert log =~ "процесс агрегата: запущен: type=account aggregate_id=#{dump(id)}"
      assert_received {:start, %{type: "account"}}
      assert_received {:ran_in, server}
      assert server != self()
      assert [{^server, _value}] = Registry.lookup(Account.Process.Registry, id)
      assert_received {:load, %{op: :get_decision, result: :ok}}

      assert Account.Process.execute(id, Version.new!(1), close(), Context.new(), report(self())) ==
               {:ok, Version.new!(3)}

      assert_received {:ran_in, ^server}
      assert_received {:load, %{op: :refresh, result: :ok}}
      refute_received {:load, _metadata}
      refute_received {:start, _metadata}
      assert stream_tags(id) == ["account.opened", "account.frozen", "account.closed"]

      assert_received {:execute, %{type: "account", mode: :process, result: :ok},
                       %{duration: duration, queue: queue, retries: 0}}

      assert is_integer(duration)
      assert is_integer(queue) and queue >= 0
    end

    test "конкурентные команды одного агрегата — по одной в его процессе, без :version_mismatch" do
      start_tree!(Account.Process)
      id = Account.ID.new()
      test_pid = self()
      {:ok, _version} = Account.Process.execute(id, :current, open("Счёт"), Context.new())

      tasks =
        for n <- 1..5 do
          Task.async(fn ->
            Account.Process.execute(
              id,
              :current,
              rename("Имя #{n}"),
              Context.new(),
              report(test_pid)
            )
          end)
        end

      versions = for {:ok, version} <- Enum.map(tasks, &Task.await/1), do: Version.value(version)
      assert Enum.sort(versions) == [2, 3, 4, 5, 6]

      servers =
        for _command <- 1..5 do
          assert_received {:ran_in, server}
          server
        end

      assert [_server] = Enum.uniq(servers)
      assert stream_tags(id) == ["account.opened" | List.duplicate("account.renamed", 5)]

      for _call <- 1..6,
          do: assert_received({:execute, %{mode: :process, result: :ok}, %{retries: 0}})

      assert_received {:start, _metadata}
      refute_received {:start, _metadata}
    end

    test "запись в обход процесса через репозиторий дочитывает refresh следующей команды" do
      start_tree!(Account.Process)
      id = Account.ID.new()
      {:ok, _version} = Account.Process.execute(id, :current, open("Счёт"), Context.new())
      _written = write!(Account.Repo.Pg, id, [rename("Отгрузка")])
      :ok = attach_load()

      assert Account.Process.execute(id, Version.new!(2), freeze(), Context.new()) ==
               {:ok, Version.new!(3)}

      assert_received {:load, %{op: :refresh, result: :ok}}
      refute_received {:load, _metadata}
      assert stream_tags(id) == ["account.opened", "account.renamed", "account.frozen"]
      assert_received {:execute, %{mode: :process, result: :ok}, %{retries: 0}}
    end

    test "отказ записи в процессе — повтор новой транзакцией с дочитыванием хвоста" do
      start_tree!(Account.RacyProcess)
      id = Account.ID.new()
      {:ok, _version} = Account.RacyProcess.execute(id, :current, open("Счёт"), Context.new())
      :ok = Account.RacyRepo.Pg.race(id, 2)
      :ok = attach_load()

      assert Account.RacyProcess.execute(id, :current, rename("Отгрузка"), Context.new(), record(self())) ==
               {:ok, Version.new!(2)}

      for _attempt <- 1..3, do: assert_received({:load, %{op: :refresh, result: :ok}})
      refute_received {:load, _metadata}
      assert_received {:callback, [%Account.Event.Renamed{}]}
      refute_received {:callback, _events}
      assert names() == ["events=1"]
      assert stream_tags(id) == ["account.opened", "account.renamed"]
      assert_received {:execute, %{mode: :process, result: :ok}, %{retries: 0}}
      assert_received {:execute, %{mode: :process, result: :ok}, %{retries: 2}}
      assert {:ok, _version} = Account.RacyProcess.execute(id, Version.new!(2), freeze(), Context.new())
    end

    test "watch_list — верхний супервизор при enabled: true, пусто при enabled: false" do
      assert Account.Process.watch_list(enabled: true) ==
               [%{component: "es_aggregate_process:account", name: Account.Process}]

      assert Account.Process.watch_list(enabled: false, idle_timeout: 1_000) == []

      assert_raise ArgumentError, ~r/нет обязательной опции :enabled/, fn ->
        Account.Process.watch_list(retries: 1)
      end
    end
  end

  describe "процесс на id: сбои и уход" do
    test "простой idle_timeout: — {:stop, :normal}, stop :idle и debug; следующая команда — новый процесс" do
      start_tree!(Account.Process, idle_timeout: 30_000)
      id = Account.ID.new()
      {:ok, _version} = Account.Process.execute(id, :current, open("Счёт"), Context.new(), report(self()))
      assert_received {:ran_in, server}
      ref = Process.monitor(server)

      # Простой GenServer приходит процессу сообщением `:timeout` — тест шлёт его сам, без таймера.
      log =
        capture_at(:debug, fn ->
          send(server, :timeout)
          assert_receive {:DOWN, ^ref, :process, ^server, :normal}
        end)

      assert log =~
               "процесс агрегата: ушёл по простою: type=account aggregate_id=#{dump(id)} " <>
                 "idle_timeout=30000"

      assert_received {:stop, %{type: "account", reason: :idle}}
      assert Registry.lookup(Account.Process.Registry, id) == []

      assert {:ok, _version} =
               Account.Process.execute(
                 id,
                 Version.new!(1),
                 freeze(),
                 Context.new(),
                 report(self())
               )

      assert_received {:ran_in, restarted}
      assert restarted != server
      assert stream_tags(id) == ["account.opened", "account.frozen"]
    end

    test "команда, простоявшая в очереди до дедлайна, отбрасывается до транзакции" do
      start_tree!(Account.Process)
      id = Account.ID.new()
      test_pid = self()
      :ok = attach_load()

      blocker =
        Task.async(fn ->
          Account.Process.execute(id, :current, open("Счёт"), Context.new(), fn _events ->
            send(test_pid, {:blocked, self()})

            receive do
              :release -> :ok
            end
          end)
        end)

      assert_receive {:blocked, server}

      assert {:timeout, _call} =
               catch_exit(
                 Account.Process.execute(
                   id,
                   :current,
                   rename("Отгрузка"),
                   Context.new(),
                   record(self()),
                   timeout: 50
                 )
               )

      assert_received {:execute, %{mode: :process, result: :exit}, %{queue: 0, retries: 0}}

      log =
        capture_log(fn ->
          send(server, :release)
          assert {:ok, _version} = Task.await(blocker)
          assert {:ok, _version} = Account.Process.execute(id, :current, freeze(), Context.new())
        end)

      assert log =~
               "процесс агрегата: просроченная команда отброшена: type=account " <>
                 "aggregate_id=#{dump(id)}"

      assert_received {:load, %{op: :get_decision}}
      assert_received {:load, %{op: :refresh}}
      refute_received {:load, _metadata}
      refute_received {:callback, _events}
      assert names() == []
      assert stream_tags(id) == ["account.opened", "account.frozen"]
    end

    test "дедлайн истёк посреди команды — exit вызывающему, транзакция откатывается до commit" do
      start_tree!(Account.Process)
      id = Account.ID.new()
      test_pid = self()

      caller =
        Task.async(fn ->
          catch_exit(
            Account.Process.execute(
              id,
              :current,
              open("Счёт"),
              Context.new(),
              fn events ->
                :ok = record(test_pid).(events)
                send(test_pid, {:blocked, self()})

                receive do
                  :release -> :ok
                end
              end,
              timeout: 50
            )
          )
        end)

      assert_receive {:blocked, server}
      assert {:timeout, _call} = Task.await(caller)

      log =
        capture_log(fn ->
          send(server, :release)
          assert {:ok, _version} = Account.Process.execute(id, :current, open("Счёт"), Context.new())
        end)

      assert log =~ "процесс агрегата: просроченная команда отброшена: type=account"
      assert_received {:callback, [%Account.Event.Opened{}]}
      assert names() == []
      assert stream_tags(id) == ["account.opened"]
      assert_received {:execute, %{mode: :process, result: :exit}, _measurements}
    end

    test "raise в decide роняет процесс: exit вызывающему, stop :error; следующая команда — новый" do
      start_tree!(Account.Process)
      id = Account.ID.new()
      %{at: at, by: by} = open("Счёт")
      {:ok, _version} = Account.Process.execute(id, :current, open("Счёт"), Context.new(), report(self()))
      assert_received {:ran_in, server}
      ref = Process.monitor(server)

      _log =
        capture_log(fn ->
          assert {{:function_clause, [{Account, :decide, _args, _location} | _stack]}, _call} =
                   catch_exit(
                     Account.Process.execute(
                       id,
                       :current,
                       %Unknown{at: at, by: by},
                       Context.new()
                     )
                   )

          assert_receive {:DOWN, ^ref, :process, ^server, {:function_clause, _stacktrace}}
        end)

      assert_received {:stop, %{type: "account", reason: :error}}
      assert_received {:execute, %{mode: :process, result: :exit}, %{queue: 0, retries: 0}}

      assert {:ok, _version} =
               Account.Process.execute(
                 id,
                 Version.new!(1),
                 freeze(),
                 Context.new(),
                 report(self())
               )

      assert_received {:ran_in, restarted}
      assert restarted != server
      assert stream_tags(id) == ["account.opened", "account.frozen"]
    end

    test "процесс ушёл между командами — :noproc: старт нового и повтор вызова" do
      start_tree!(Account.Process)
      id = Account.ID.new()
      {:ok, _version} = Account.Process.execute(id, :current, open("Счёт"), Context.new(), report(self()))
      assert_received {:ran_in, server}
      :ok = DynamicSupervisor.terminate_child(Account.Process.Supervisor, server)
      :ok = attach_load()

      assert {:ok, _version} =
               Account.Process.execute(
                 id,
                 Version.new!(1),
                 freeze(),
                 Context.new(),
                 report(self())
               )

      assert_received {:ran_in, restarted}
      assert restarted != server
      assert_received {:load, %{op: :get_decision, result: :ok}}
      for _start <- 1..2, do: assert_received({:start, %{type: "account"}})
    end

    test "raise в колбэке после append — exit вызывающему, события и записи колбэка откатываются" do
      start_tree!(Account.Process)
      id = Account.ID.new()
      test_pid = self()

      _log =
        capture_log(fn ->
          assert {{%RuntimeError{message: "колбэк"}, _stacktrace}, _call} =
                   catch_exit(
                     Account.Process.execute(
                       id,
                       :current,
                       open("Счёт"),
                       Context.new(),
                       fn events ->
                         :ok = record(test_pid).(events)
                         raise "колбэк"
                       end
                     )
                   )
        end)

      assert_received {:callback, [%Account.Event.Opened{}]}
      assert_received {:stop, %{type: "account", reason: :error}}
      assert names() == []
      assert stream_tags(id) == []
    end

    test "колбэк вернул {:error, :expired} — ошибка колбэка вызывающему, а не истёкший дедлайн" do
      start_tree!(Account.Process)
      id = Account.ID.new()

      assert {:error, :expired} =
               Account.Process.execute(id, :current, open("Счёт"), Context.new(), fn _events ->
                 {:error, :expired}
               end)

      assert stream_tags(id) == []
      assert_received {:execute, %{mode: :process, result: :error}, %{retries: 0}}
    end
  end

  describe "процесс на id: окружение вызывающего" do
    test "Logger.metadata — на время команды; Repo.Sc — таблица процесса, таблица вызывающего цела" do
      start_tree!(Account.Process)
      id = Account.ID.new()
      test_pid = self()
      context = Repo.Sc.init(Context.new())
      stored = Repo.Sc.put(context, %Account{id: id})

      # Ключ — метка окружения вызывающего для проверки в колбэке, форматтер логов его не выводит.
      # credo:disable-for-next-line Credo.Check.Warning.MissedMetadataKeyInLoggerConfig
      :ok = Logger.metadata(request_id: "r-1")

      shadow_copies = fn pid ->
        for table <- :ets.all(),
            :ets.info(table, :owner) == pid and :ets.info(table, :name) == :shadow_copy,
            do: table
      end

      env = fn _events ->
        send(test_pid, {:env, self(), Logger.metadata(), shadow_copies.(self())})
        :ok
      end

      assert {:ok, _version} = Account.Process.execute(id, :current, open("Счёт"), context, env)
      assert_received {:env, server, metadata, [_table]}
      assert metadata[:request_id] == "r-1"
      assert shadow_copies.(server) == []
      assert Repo.Sc.find(context, Account, id) == stored

      :ok = Logger.reset_metadata()
      assert {:ok, _version} = Account.Process.execute(id, :current, rename("Отгрузка"), Context.new(), env)
      assert_received {:env, ^server, metadata, [_table]}
      refute Keyword.has_key?(metadata, :request_id)
    end
  end

  describe "команда" do
    test "get → execute/2 → append → колбэк с событиями команды" do
      start!(Account.Process)
      id = Account.ID.new()

      assert Account.Process.execute(id, :current, open("Счёт"), Context.new()) == {:ok, Version.new!(1)}

      assert Account.Process.execute(id, Version.new!(1), close(), Context.new(), record(self())) ==
               {:ok, Version.new!(3)}

      assert_received {:callback, [%Account.Event.Frozen{}, %Account.Event.Closed{}]}
      assert stream_tags(id) == ["account.opened", "account.frozen", "account.closed"]

      assert_received {:execute, %{type: "account", mode: :inline, result: :ok},
                       %{duration: duration, queue: 0, retries: 0}}

      assert is_integer(duration)
    end

    test "колбэк пишет через DAO в транзакции команды и откатывается вместе с ней" do
      start!(Account.Process)
      id = Account.ID.new()
      failed = Error.app(code: :callback_failed, ns: :fake)

      assert {:ok, _version} =
               Account.Process.execute(id, :current, open("Счёт"), Context.new(), record(self()))

      assert names() == ["events=1"]

      assert {:error, ^failed} =
               Account.Process.execute(
                 id,
                 :current,
                 rename("Отгрузка"),
                 Context.new(),
                 fn events ->
                   :ok = record(self()).(events)
                   {:error, failed}
                 end
               )

      assert names() == ["events=1"]
      assert stream_tags(id) == ["account.opened"]
      assert_received {:execute, %{result: :error}, %{retries: 0}}
    end

    test "команда без событий — версия прежняя, на пустом потоке {:ok, nil}" do
      start!(Account.Process)
      id = Account.ID.new()

      assert Account.Process.execute(id, :current, check(), Context.new(), record(self())) == {:ok, nil}
      assert_received {:callback, []}
      assert stream_tags(id) == []

      assert {:ok, _version} = Account.Process.execute(id, :current, open("Счёт"), Context.new())

      assert Account.Process.execute(id, Version.new!(1), check(), Context.new()) ==
               {:ok, Version.new!(1)}

      assert stream_tags(id) == ["account.opened"]
      for _call <- 1..3, do: assert_received({:execute, %{result: :ok}, %{retries: 0}})
    end

    test "колбэк вернул не :ok | {:error, _} — исключение до commit, без записи" do
      start!(Account.Process)
      id = Account.ID.new()

      assert_raise CaseClauseError, fn ->
        Account.Process.execute(id, :current, open("Счёт"), Context.new(), fn _events ->
          {:ok, :job}
        end)
      end

      assert stream_tags(id) == []
    end

    test "отказ decide — {:error, _} без записи и без колбэка" do
      start!(Account.Process)
      id = Account.ID.new()

      assert {:error, %Error{kind: :domain, code: :not_found}} =
               Account.Process.execute(
                 id,
                 :current,
                 rename("Отгрузка"),
                 Context.new(),
                 record(self())
               )

      refute_received {:callback, _events}
      assert stream_tags(id) == []
      assert_received {:execute, %{result: :error}, %{retries: 0}}
    end
  end

  describe "явная версия на пустом потоке" do
    test "enabled: false — отказ decide как есть, принятое решение — :version_mismatch без записи и повтора" do
      start!(Account.Process)

      assert_unborn_version(Account.ID.new())

      for result <- ~w(error version_mismatch version_mismatch)a,
          do: assert_received({:execute, %{mode: :inline, result: ^result}, %{retries: 0}})
    end

    test "enabled: true — то же при чтении процесса и от закэшированного незаведённого агрегата" do
      start_tree!(Account.Process)
      id = Account.ID.new()

      assert_unborn_version(id)
      assert Account.Process.execute(id, :current, check(), Context.new()) == {:ok, nil}
      assert_unborn_version(id)

      for result <- ~w(error version_mismatch version_mismatch ok error version_mismatch version_mismatch)a,
          do: assert_received({:execute, %{mode: :process, result: ^result}, %{retries: 0}})

      assert_received {:start, _metadata}
      refute_received {:start, _metadata}
    end
  end

  describe "резерв ключа" do
    test "enabled: false — резервы пишет append без колбэка: занятое название — отказ без записи" do
      start!(Account.KeyedProcess)
      [id, rival] = [Account.ID.new(), Account.ID.new()]

      assert {:ok, _version} = Account.KeyedProcess.execute(id, :current, open("Счёт"), Context.new())
      assert Account.NameKey.find(Account.Name.new!("Счёт"), Context.new()) == id

      assert {:error, %Error{module: Account.KeyedRepo, code: :name_taken}} =
               Account.KeyedProcess.execute(rival, :current, open("Счёт"), Context.new())

      assert stream_tags(rival) == []
      assert_received {:execute, %{mode: :inline, result: :ok}, %{retries: 0}}
      assert_received {:execute, %{mode: :inline, result: :error}, %{retries: 0}}
    end

    test "enabled: true — переименование в процессе на id переносит ключ" do
      start_tree!(Account.KeyedProcess)
      id = Account.ID.new()

      assert {:ok, _version} = Account.KeyedProcess.execute(id, :current, open("Счёт"), Context.new())
      assert {:ok, _version} = Account.KeyedProcess.execute(id, :current, rename("Отгрузка"), Context.new())

      assert Account.NameKey.find(Account.Name.new!("Счёт"), Context.new()) == nil
      assert Account.NameKey.find(Account.Name.new!("Отгрузка"), Context.new()) == id
      assert_received {:execute, %{mode: :process, result: :ok}, %{retries: 0}}
    end
  end

  describe "повтор после отказа записи" do
    test "отказ append при :current — повтор новой транзакцией с колбэком" do
      start!(Account.RacyProcess)
      id = Account.ID.new()
      name = Account.Name.new!("Отгрузка")
      {:ok, _version} = Account.RacyProcess.execute(id, :current, open("Счёт"), Context.new())
      :ok = Account.RacyRepo.Pg.race(id, 2)
      :ok = attach_load()

      log =
        capture_at(:debug, fn ->
          assert Account.RacyProcess.execute(id, :current, rename("Отгрузка"), Context.new(), record(self())) ==
                   {:ok, Version.new!(2)}
        end)

      assert log =~
               "транзакция команды: повтор после отказа записи: aggregate_id=#{dump(id)} retry=1"

      assert log =~ "retry=2"
      refute log =~ "retry=3"

      assert_received {:callback, [%Account.Event.Renamed{}]}
      refute_received {:callback, _events}
      for _attempt <- 1..3, do: assert_received({:load, %{op: :get_decision, result: :ok}})
      refute_received {:load, _metadata}
      assert names() == ["events=1"]
      assert stream_tags(id) == ["account.opened", "account.renamed"]
      assert {:ok, %Account{name: ^name}} = Account.Repo.Pg.get(id, :current, Context.new())

      assert_received {:execute, %{result: :ok}, %{retries: 0}}
      assert_received {:execute, %{result: :ok}, %{retries: 2}}
      assert retry_lines(log) == 2
    end

    test "отказ append при явной версии — повтор: сверка прошла, отказало хранилище" do
      start!(Account.RacyProcess)
      id = Account.ID.new()
      {:ok, _version} = Account.RacyProcess.execute(id, :current, open("Счёт"), Context.new())
      :ok = Account.RacyRepo.Pg.race(id, 1)

      log =
        capture_at(:debug, fn ->
          assert Account.RacyProcess.execute(
                   id,
                   Version.new!(1),
                   rename("Отгрузка"),
                   Context.new(),
                   record(self())
                 ) == {:ok, Version.new!(2)}
        end)

      assert retry_lines(log) == 1
      assert names() == ["events=1"]
      assert stream_tags(id) == ["account.opened", "account.renamed"]
      assert_received {:execute, %{result: :ok}, %{retries: 1}}
    end

    test "отказ хранилища из колбэка по соседнему потоку — повтор вместе с командой" do
      start!(Account.RacyProcess)
      [id, neighbour] = [Account.ID.new(), Account.ID.new()]
      {:ok, _version} = Account.RacyProcess.execute(id, :current, open("Счёт"), Context.new())
      :ok = Account.RacyRepo.Pg.race(neighbour, 1)

      log =
        capture_at(:debug, fn ->
          assert Account.RacyProcess.execute(
                   id,
                   Version.new!(1),
                   rename("Отгрузка"),
                   Context.new(),
                   open_neighbour(self(), neighbour)
                 ) == {:ok, Version.new!(2)}
        end)

      assert retry_lines(log) == 1
      assert_received {:callback, [%Account.Event.Renamed{}]}
      assert_received {:callback, [%Account.Event.Renamed{}]}
      refute_received {:callback, _events}
      assert stream_tags(id) == ["account.opened", "account.renamed"]
      assert stream_tags(neighbour) == ["account.opened"]
      assert_received {:execute, %{result: :ok}, %{retries: 1}}
    end

    test "исчерпание retries: — отказ вызывающему и warning" do
      start!(Account.RacyProcess, retries: 1)
      id = Account.ID.new()
      {:ok, _version} = Account.RacyProcess.execute(id, :current, open("Счёт"), Context.new())
      :ok = Account.RacyRepo.Pg.race(id, 2)

      log =
        capture_log(fn ->
          assert {:error, %Error{code: :version_mismatch}} =
                   Account.RacyProcess.execute(
                     id,
                     :current,
                     rename("Отгрузка"),
                     Context.new(),
                     record(self())
                   )
        end)

      assert log =~
               "транзакция команды: повторы после отказа записи исчерпаны: " <>
                 "aggregate_id=#{dump(id)} retries=1"

      refute_received {:callback, _events}
      assert names() == []
      assert stream_tags(id) == ["account.opened"]
      assert_received {:execute, %{result: :version_mismatch}, %{retries: 1}}
    end

    test "сверка ожидаемой версии повтора не даёт: source: :expected" do
      start!(Account.RacyProcess)
      id = Account.ID.new()
      dumped = dump(id)

      log =
        capture_at(:debug, fn ->
          assert {:error, %Error{code: :version_mismatch} = empty} =
                   Account.RacyProcess.execute(id, Version.new!(1), open("Счёт"), Context.new())

          assert empty.detail ==
                   %{aggregate_id: dumped, expected: 1, actual: nil, source: :expected}

          {:ok, _version} = Account.RacyProcess.execute(id, :current, open("Счёт"), Context.new())

          assert {:error, %Error{code: :version_mismatch} = stale} =
                   Account.RacyProcess.execute(
                     id,
                     Version.new!(2),
                     rename("Отгрузка"),
                     Context.new(),
                     record(self())
                   )

          assert stale.detail ==
                   %{aggregate_id: dumped, expected: 2, actual: 1, source: :expected}
        end)

      assert retry_lines(log) == 0
      refute_received {:callback, _events}
      assert stream_tags(id) == ["account.opened"]
      assert_received {:execute, %{result: :version_mismatch}, %{retries: 0}}
      assert_received {:execute, %{result: :ok}, %{retries: 0}}
      assert_received {:execute, %{result: :version_mismatch}, %{retries: 0}}
    end

    test "дедлайн истёк на попытке — следующая не стартует: без чтения, записи и колбэка" do
      start_tree!(Account.RacyProcess)
      id = Account.ID.new()
      {:ok, _version} = Account.RacyProcess.execute(id, :current, open("Счёт"), Context.new())
      :ok = Account.RacyRepo.Pg.race(id, 1)
      :ok = attach_load()
      :ok = block_load()

      log =
        capture_log(fn ->
          assert {:timeout, _call} =
                   catch_exit(
                     Account.RacyProcess.execute(
                       id,
                       :current,
                       rename("Отгрузка"),
                       Context.new(),
                       record(self()),
                       timeout: 50
                     )
                   )

          # Чтение попытки держится до exit вызывающего: дальше она идёт с истёкшим дедлайном.
          assert_received {:blocked, server}
          send(server, :release)

          assert {:ok, _version} = Account.RacyProcess.execute(id, :current, freeze(), Context.new())
        end)

      assert log =~ "процесс агрегата: просроченная команда отброшена: type=account"

      # Чтения — по одному на попытку: отказавшая попытка команды и команда после неё.
      for _read <- 1..2, do: assert_received({:load, %{op: :refresh, result: :ok}})
      refute_received {:load, _metadata}
      refute_received {:callback, _events}
      assert names() == []
      assert stream_tags(id) == ["account.opened", "account.frozen"]
      assert_received {:execute, %{mode: :process, result: :exit}, _measurements}
    end
  end

  describe "ошибки программиста" do
    test "внутри Transact.run — ArgumentError" do
      start!(Account.Process)

      assert_raise ArgumentError, ~r/Account\.Process\.execute вызван внутри транзакции/, fn ->
        Transact.run(TestRepo, fn ->
          Account.Process.execute(Account.ID.new(), :current, open("Счёт"), Context.new())
        end)
      end
    end

    test "дерево не запущено и отметки нет — RuntimeError" do
      assert_raise RuntimeError, ~r/ProcessTest\.Unstarted не запущен/, fn ->
        Unstarted.execute(Account.ID.new(), :current, open("Счёт"), Context.new())
      end
    end

    test "timeout: не положительное целое — ArgumentError" do
      start!(Account.Process)
      opts = [timeout: :infinity]

      assert_raise ArgumentError,
                   ~r/:timeout — ожидается положительное целое, получено :infinity/,
                   fn ->
                     Account.Process.execute(
                       Account.ID.new(),
                       :current,
                       open("Счёт"),
                       Context.new(),
                       nil,
                       opts
                     )
                   end
    end

    test "неизвестная опция вызова — ArgumentError" do
      start!(Account.Process)

      assert_raise ArgumentError, ~r/unknown keys \[:retries\]/, fn ->
        Account.Process.execute(Account.ID.new(), :current, open("Счёт"), Context.new(), nil, retries: 5)
      end
    end
  end

  describe "span" do
    setup do
      :ok = OtelFixture.attach()
      :ok
    end

    test "execute <тип> — в трейсе вызывающего: адрес, команда, режим и число повторов" do
      start!(Account.RacyProcess)
      id = Account.ID.new()
      {:ok, _version} = Account.RacyProcess.execute(id, :current, open("Счёт"), Context.new())
      :ok = Account.RacyRepo.Pg.race(id, 1)
      _spans = OtelFixture.drain(0)

      Otel.span("usecase", [], fn ->
        assert {:ok, _version} = Account.RacyProcess.execute(id, :current, rename("Отгрузка"), Context.new())
      end)

      spans = OtelFixture.drain()
      execute = OtelFixture.find(spans, "execute account")

      assert execute.kind == :internal
      assert execute.parent_span_id == OtelFixture.find(spans, "usecase").span_id
      assert execute.status == :undefined

      assert execute.attributes == %{
               "core.es.aggregate.type" => "account",
               "core.es.aggregate.id" => dump(id),
               "core.es.command" => "Core.EsFixture.Account.Cmd.Rename",
               "core.es.execute.mode" => "inline",
               "core.es.retries" => 1
             }
    end

    test "прикладная ошибка — record_error/1; доменный отказ статус span'а не меняет" do
      start!(Account.Process)
      id = Account.ID.new()
      failed = Error.app(code: :callback_failed, ns: :fake)
      _spans = OtelFixture.drain(0)

      assert {:error, %Error{code: :not_found}} =
               Account.Process.execute(id, :current, rename("Отгрузка"), Context.new())

      refused = OtelFixture.drain() |> OtelFixture.find("execute account")
      assert refused.status == :undefined
      refute Map.has_key?(refused.attributes, "error.type")

      assert {:error, ^failed} =
               Account.Process.execute(id, :current, open("Счёт"), Context.new(), fn _events ->
                 {:error, failed}
               end)

      errored = OtelFixture.drain() |> OtelFixture.find("execute account")
      assert errored.attributes["error.type"] == "fake/callback_failed"
      assert {:error, _message} = errored.status
    end

    test "процесс на id: span охватывает очередь, event dequeued; колбэк — в трейсе вызывающего" do
      start_tree!(Account.Process)
      id = Account.ID.new()
      test_pid = self()
      _spans = OtelFixture.drain(0)

      Otel.span("usecase", [], fn ->
        assert {:ok, _version} =
                 Account.Process.execute(id, :current, open("Счёт"), Context.new(), fn _events ->
                   send(test_pid, {:ran_in, self()})
                   Otel.span("callback", [], fn -> :ok end)
                 end)
      end)

      spans = OtelFixture.drain()
      execute = OtelFixture.find(spans, "execute account")

      assert execute.parent_span_id == OtelFixture.find(spans, "usecase").span_id
      assert OtelFixture.find(spans, "callback").parent_span_id == execute.span_id
      assert execute.events == ["dequeued"]
      assert execute.status == :undefined
      assert %{"core.es.execute.mode" => "process", "core.es.retries" => 0} = execute.attributes

      # Контекст OTel живёт в словаре процесса: после команды span'а вызывающего в нём нет.
      assert_received {:ran_in, server}
      {:dictionary, dictionary} = Process.info(server, :dictionary)

      refute Enum.any?(dictionary, fn {_key, value} ->
               is_map(value) and is_map_key(value, {:otel_tracer, :span_ctx})
             end)
    end
  end

  defp start(process, opts) do
    %{start: {mod, fun, args}} = process.child_spec(opts)
    apply(mod, fun, args)
  end

  defp start!(process, opts \\ []) do
    :ignore = start(process, [enabled: false] ++ opts)
    :ok
  end

  defp start_tree!(process, opts \\ []) do
    {:ok, _tree} = start_supervised({process, [enabled: true] ++ opts})
    :ok
  end

  # Колбэк команды: сообщает тесту процесс, в котором исполняется.
  defp report(test_pid) do
    fn _events ->
      send(test_pid, {:ran_in, self()})
      :ok
    end
  end

  # Колбэк команды: сообщает тесту события и пишет строку через DAO в транзакции команды.
  defp record(test_pid) do
    fn events ->
      true = TestRepo.in_transaction?()
      send(test_pid, {:callback, events})

      row = %{
        aggregate_type: "process",
        aggregate_id: Ecto.UUID.generate(),
        name: "events=#{length(events)}",
        closed: false
      }

      {1, nil} = TestRepo.insert_all(EsFixture.Projection.Row, [row])
      :ok
    end
  end

  defp names, do: TestRepo.all(from(r in EsFixture.Projection.Row, select: r.name))

  defp retry_lines(log) do
    log
    |> String.split("\n")
    |> Enum.count(&(&1 =~ "транзакция команды: повтор после отказа записи:"))
  end

  # Колбэк команды, который пишет в соседний поток: поставленная на него гонка отказывает
  # отказом хранилища, и повторяется вся команда, а не запись соседа.
  defp open_neighbour(test_pid, neighbour) do
    fn events ->
      send(test_pid, {:callback, events})
      context = Context.new()
      decide = &Account.execute(&1, open("Соседний"))

      case Account.RacyRepo.Pg.get_decision(neighbour, :current, context, decide) do
        {:ok, {neighbour_events, _state}} ->
          Account.RacyRepo.Pg.append(neighbour_events, context)

        {:error, _reason} = error ->
          error
      end
    end
  end

  # Команды с `%Version{}` над пустым потоком: переименование decide отклоняет, открытие и сверку —
  # принимает, с событиями и без.
  defp assert_unborn_version(id) do
    assert {:error, %Error{kind: :domain, code: :not_found}} =
             Account.Process.execute(id, Version.new!(1), rename("Отгрузка"), Context.new(), record(self()))

    for command <- [open("Счёт"), check()] do
      assert {:error, %Error{code: :version_mismatch} = error} =
               Account.Process.execute(id, Version.new!(1), command, Context.new(), record(self()))

      assert error.detail == %{aggregate_id: dump(id), expected: 1, actual: nil, source: :expected}
    end

    refute_received {:callback, _events}
    assert stream_tags(id) == []
    assert names() == []
  end

  # Восстановление агрегата в процессе теста — факт чтения каждой попытки.
  defp attach_load do
    handler_id = "es-aggregate-load-#{inspect(self())}"

    :ok =
      :telemetry.attach(
        handler_id,
        Telemetry.event([:es, :aggregate, :load]),
        fn _event, _measurements, metadata, test_pid -> send(test_pid, {:load, metadata}) end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  # Первое восстановление агрегата держится до `:release` от теста — попытка длиннее дедлайна
  # команды; хендлер снимает себя сам, следующие чтения идут без задержки.
  defp block_load do
    handler_id = "es-aggregate-block-load-#{inspect(self())}"

    :ok =
      :telemetry.attach(
        handler_id,
        Telemetry.event([:es, :aggregate, :load]),
        fn _event, _measurements, _metadata, {test_pid, id} ->
          :ok = :telemetry.detach(id)
          send(test_pid, {:blocked, self()})

          receive do
            :release -> :ok
          end
        end,
        {self(), handler_id}
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp erase_mark(process), do: :persistent_term.erase({Es.Aggregate.Process, process})

  # Уровень логов тестов — `:warning`: `info` и `debug` процесса видны только с уровнем его модулей.
  defp capture_at(level, fun) do
    Logger.put_module_level(@logging, level)

    try do
      capture_log(fun)
    after
      Logger.delete_module_level(@logging)
    end
  end
end
