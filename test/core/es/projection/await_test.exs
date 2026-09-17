defmodule Core.Es.Projection.AwaitTest do
  # Отметка дерева — глобальное состояние ноды; блокировка пачки и строка чекпоинта держатся до конца
  # sandbox-транзакции теста, экспортёр span'ов — глобальный ресурс SDK.
  use Core.DataCase, async: false

  import Core.EsAggregateRepoContract, only: [close: 0, dump: 1, open: 1, write!: 3]

  alias Core.Config
  alias Core.Context
  alias Core.Error
  alias Core.Es
  alias Core.EsFixture
  alias Core.EsFixture.Account
  alias Core.EventFixture
  alias Core.Helper.Transact
  alias Core.Otel
  alias Core.OtelFixture
  alias Core.StateStoredFixture
  alias Core.StateStoredFixture.Entity
  alias Core.Telemetry
  alias Core.Version
  alias Ecto.Adapters.SQL.Sandbox

  require Config

  @projection EsFixture.Projection
  @account_repo Config.repo!(Account.Repo)
  @entity_repo Config.repo!(StateStoredFixture.Repo)
  @mark_key Es.Projection.Supervisor.Mark
  @quiet [
    idle_min_ms: 60_000,
    poll_interval_ms: 60_000,
    retry_min_ms: 60_000,
    retry_max_ms: 60_000
  ]
  @distant_steps [await_min_ms: 60_000, await_max_ms: 60_000]

  defmodule AccountOnly do
    @moduledoc false

    use Core.Es.Projection,
      name: "await_account_only",
      events: [Core.EsFixture.Account.Event.Opened]

    @impl true
    def project(_event), do: :ok

    @impl true
    def clear, do: :ok
  end

  defmodule Failing do
    @moduledoc false

    require Core.Error

    use Core.Es.Projection,
      name: "await_failing",
      events: [Core.EsFixture.Account.Event.Opened]

    @impl true
    def project(_event), do: {:error, Core.Error.app(code: :project_failed, ns: :fake)}

    @impl true
    def clear, do: :ok
  end

  defmodule Bumped do
    @moduledoc false

    # `EsFixture.Projection` новой выкладки: то же имя и read-модель, версия выше.
    use Core.Es.Projection,
      name: "es_fixture",
      events: [
        Core.EsFixture.Account.Event.Opened,
        Core.EsFixture.Account.Event.Closed,
        Core.EventFixture.Event.Created,
        Core.EventFixture.Event.Closed
      ],
      version: 2

    @impl true
    defdelegate project(event), to: Core.EsFixture.Projection

    @impl true
    defdelegate clear, to: Core.EsFixture.Projection
  end

  setup do
    handler_id = "es-projection-await-#{inspect(self())}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          Telemetry.event([:es, :projection, :await]),
          Telemetry.event([:es, :projection, :cycle])
        ],
        fn event, measurements, metadata, test_pid ->
          send(test_pid, {List.last(event), metadata, measurements})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    on_exit(fn -> :persistent_term.erase(@mark_key) end)
  end

  describe "await: :inline" do
    test "запись через репозитории обоих видов → прогон в процессе теста → read-модель с событиями" do
      mark!([@projection], await: :inline)
      account = Account.ID.new()
      entity = EventFixture.AggID.new()
      write!(@account_repo, account, [open("Счёт")])
      insert_entity!(entity, "Агрегат")

      assert :ok = @projection.await(Account, account, 1_000)

      assert rows() == [
               {"account", dump(account), "Счёт", false},
               {"fixture", dump(entity), "Агрегат", false}
             ]

      close_entity!(entity, "Агрегат")

      assert :ok = @projection.await(EventFixture, entity, 1_000)
      assert {"fixture", _id, "Агрегат", true} = List.last(rows())
      assert_receive {:await, %{projection: "es_fixture", result: :ok}, _measurements}
    end

    test "исход прогона не :idle — raise с исходом и именем проекции" do
      account = Account.ID.new()
      write!(@account_repo, account, [open("Счёт")])

      mark!([Failing], await: :inline)

      assert_raise RuntimeError, ~r/await_failing.*project_failed/s, fn ->
        Failing.await(Account, account, 1_000)
      end

      :ok = insert_checkpoint!("es_fixture", 2)
      mark!([@projection], await: :inline)

      assert_raise RuntimeError, ~r/es_fixture.*:outdated/, fn ->
        @projection.await(Account, account, 1_000)
      end

      refute_received {:await, _metadata, _measurements}
    end

    test "пачку держит другое соединение — raise с :locked" do
      account = Account.ID.new()
      write!(@account_repo, account, [open("Счёт")])
      mark!([@projection], await: :inline)
      :ok = hold_batch_lock!(@projection)

      assert_raise RuntimeError, ~r/es_fixture — исход :locked/, fn ->
        @projection.await(Account, account, 1_000)
      end
    end

    test "прогон дошёл до :idle, а последнее событие потока пачке не видно — raise" do
      mark!([@projection], await: :inline)

      # Запись чекпоинта даёт транзакции теста xid: событие, закоммиченное позже, пачка не видит.
      assert :ok = Es.Projection.Test.run_until_idle(@projection)
      account = Account.ID.new()
      :ok = commit_event!(account)

      assert_raise RuntimeError, ~r/es_fixture — исход \{:idle, :behind\}/, fn ->
        @projection.await(Account, account, 1_000)
      end
    end
  end

  describe "await: :poll" do
    test "запись через репозиторий — сигнал чекпоинта после пачки читателя, :ok без шага ожидания" do
      # Строки чекпоинта нет — ожидание отдало бы пересборку до первой пачки читателя.
      assert :ok = Es.Projection.Test.run_until_idle(@projection)
      start_tree!([@projection], @distant_steps)
      reader = Process.whereis(@projection)
      account = Account.ID.new()

      # `wake` записи ждёт в очереди читателя, пока ожидание не застало чекпоинт отстающим.
      :ok = :sys.suspend(reader)
      write!(@account_repo, account, [open("Счёт")])
      resumed = after_checkpoint_read(fn -> :sys.resume(reader) end)

      assert :ok = @projection.await(Account, account, 5_000)
      assert :ok = Task.await(resumed)
      assert rows() == [{"account", dump(account), "Счёт", false}]

      # Сигнал пачки после ожидания в mailbox теста не попадает.
      assert_receive {:cycle, %{result: :processed}, _measurements}, 1_000
      write!(@account_repo, account, [close()])
      assert_receive {:cycle, %{result: :processed}, _measurements}, 1_000
      assert leftovers() == []
    end

    test "событие без сигнала записи — шаг ожидания будит читателя, :ok" do
      assert :ok = Es.Projection.Test.run_until_idle(@projection)
      start_tree!([@projection])
      account = Account.ID.new()

      # Вставка мимо `append`: `wake` нет, а первый тик читателя — через 60 000 мс.
      {1, nil} = TestRepo.insert_all(Es.Store.Schema, [event_row(account)])

      assert :ok = @projection.await(Account, account, 5_000)
    end

    test "таймаут — сигналы во время и после ожидания в mailbox теста не остаются" do
      assert :ok = Es.Projection.Test.run_until_idle(@projection)
      start_tree!([@projection], @distant_steps)
      account = Account.ID.new()

      # Вставка мимо `append`: читателя не будят ни запись, ни шаг ожидания.
      {1, nil} = TestRepo.insert_all(Es.Store.Schema, [event_row(account)])

      # Сигнал уходит после чтения цели и доставляется, пока ожидание читает чекпоинт, — таймаут 0 его
      # уже не принимает. На снятый к тому моменту alias runtime отбросил бы его и без вычерпывания.
      :ok =
        on_query(~s(FROM "es_events"), fn ->
          Es.Projection.Registry.signal_checkpoint("es_fixture")
        end)

      assert {:error, %Error{code: :projection_timeout}} =
               @projection.await(Account, account, 0)

      :ok = Es.Projection.Registry.wake("account")
      assert_receive {:cycle, %{result: :processed}, _measurements}, 1_000
      assert leftovers() == []
    end

    @tag :capture_log
    test "пачка читателя начала пересборку — сигнал чекпоинта, сразу :projection_rebuilding" do
      assert :ok = Es.Projection.Test.run_until_idle(Failing)
      account = Account.ID.new()
      # Дерева ещё нет: `append` читателя не будит.
      write!(@account_repo, account, [open("Счёт")])
      start_tree!([Failing], @distant_steps)

      # Строка удаляется, когда ожидание застало её отстающей: пересборку начинает пачка читателя, а
      # следующая отказывает на событии и чекпоинт не двигает.
      rebuilt =
        after_checkpoint_read(fn ->
          :ok = delete_checkpoint!("await_failing")
          Es.Projection.Registry.wake("account")
        end)

      assert {:error, %Error{code: :projection_rebuilding}} =
               Failing.await(Account, account, 5_000)

      assert :ok = Task.await(rebuilt)

      assert_receive {:cycle, %{projection: "await_failing", result: :retry}, _measurements},
                     1_000

      assert leftovers() == []
    end

    test "пустой поток и чекпоинт не ниже последнего события потока — :ok без ожидания" do
      mark!([@projection])
      account = Account.ID.new()

      assert :ok = @projection.await(Account, account, 30_000)

      write!(@account_repo, account, [open("Счёт")])
      assert :ok = Es.Projection.Test.run_until_idle(@projection)

      assert :ok = @projection.await(Account, account, 30_000)
      assert_receive {:await, %{projection: "es_fixture", result: :ok}, %{duration: duration}}
      assert is_integer(duration)
    end

    test "чекпоинт ниже последнего события потока — опрос до таймаута, :projection_timeout" do
      mark!([@projection])
      account = Account.ID.new()
      write!(@account_repo, account, [open("Счёт")])
      assert :ok = Es.Projection.Test.run_until_idle(@projection)
      write!(@account_repo, account, [close()])

      assert {:error, %Error{kind: :app, ns: :es, code: :projection_timeout} = error} =
               @projection.await(Account, account, 50)

      assert error.detail == %{projection: "es_fixture", timeout: 50}

      assert_receive {:await, %{projection: "es_fixture", result: :timeout}, %{duration: duration}}

      assert duration >= System.convert_time_unit(50, :millisecond, :native)
    end

    test "шаг опроса — от await_min_ms дерева с удвоением" do
      mark!([@projection], await_min_ms: 50, await_max_ms: 60_000)
      account = Account.ID.new()
      write!(@account_repo, account, [open("Счёт")])
      assert :ok = Es.Projection.Test.run_until_idle(@projection)
      write!(@account_repo, account, [close()])

      # Проверки на 0, 50, 150 и 350 мс, следующий шаг — позже таймаута; долгое чтение их сокращает.
      {result, reads} =
        count_checkpoint_reads(fn ->
          @projection.await(Account, account, 500)
        end)

      assert {:error, %Error{code: :projection_timeout}} = result
      assert reads in 2..4
    end

    test "шаг опроса — удвоение ограничено await_max_ms дерева" do
      mark!([@projection], await_min_ms: 10, await_max_ms: 10)
      account = Account.ID.new()
      write!(@account_repo, account, [open("Счёт")])
      assert :ok = Es.Projection.Test.run_until_idle(@projection)
      write!(@account_repo, account, [close()])

      # Шаг 10 мс — до 50 проверок за 500 мс; с пределом удвоения 100 мс их не больше 8.
      {result, reads} =
        count_checkpoint_reads(fn ->
          @projection.await(Account, account, 500)
        end)

      assert {:error, %Error{code: :projection_timeout}} = result
      assert reads > 8
    end

    test "пересборка — сразу :projection_rebuilding: строки нет, версия ниже, чекпоинт ниже цели" do
      account = Account.ID.new()
      write!(@account_repo, account, [open("Счёт")])

      mark!([@projection])

      assert {:error, %Error{} = error} =
               @projection.await(Account, account, 30_000)

      assert %{kind: :app, ns: :es, code: :projection_rebuilding} = error
      assert error.detail == %{projection: "es_fixture"}

      assert :ok = Es.Projection.Test.run_until_idle(@projection)
      write!(@account_repo, account, [close()])
      mark!([Bumped])

      assert {:error, %Error{code: :projection_rebuilding}} =
               Bumped.await(Account, account, 30_000)

      assert :processed = Es.Projection.run_once(Bumped)

      assert {:error, %Error{code: :projection_rebuilding}} =
               Bumped.await(Account, account, 30_000)

      for _await <- 1..3 do
        assert_receive {:await, %{projection: "es_fixture", result: :rebuilding}, _measurements}
      end
    end

    test "чекпоинт не ниже последнего события потока — :ok при строке старой версии и в пересборке" do
      early = Account.ID.new()
      late = Account.ID.new()
      write!(@account_repo, early, [open("Ранний")])
      assert :ok = Es.Projection.Test.run_until_idle(@projection)
      write!(@account_repo, late, [open("Поздний")])
      mark!([Bumped])

      assert :ok = Bumped.await(Account, early, 30_000)

      assert :processed = Es.Projection.run_once(Bumped)
      assert :processed = Es.Projection.run_once(Bumped, batch_size: 1)

      assert :ok = Bumped.await(Account, early, 30_000)

      assert {:error, %Error{code: :projection_rebuilding}} =
               Bumped.await(Account, late, 30_000)
    end
  end

  describe "ошибки программиста" do
    test "агрегат, на который проекция не подписана, и ID другого агрегата — FunctionClauseError" do
      mark!([AccountOnly])

      assert_raise FunctionClauseError, fn ->
        AccountOnly.await(EventFixture, EventFixture.AggID.new(), 100)
      end

      assert_raise FunctionClauseError, fn ->
        AccountOnly.await(Account, EventFixture.AggID.new(), 100)
      end
    end

    test "внутри транзакции — ArgumentError" do
      mark!([@projection])

      assert_raise ArgumentError, ~r/проекция es_fixture вызвана внутри транзакции/, fn ->
        Transact.run(TestRepo, fn ->
          @projection.await(Account, Account.ID.new(), 100)
        end)
      end
    end

    test "дерево проекций не запущено — RuntimeError" do
      :persistent_term.erase(@mark_key)

      assert_raise RuntimeError, ~r/дерево проекций не запущено/, fn ->
        @projection.await(Account, Account.ID.new(), 100)
      end
    end

    test "проекция не из projections: дерева — ArgumentError" do
      mark!([@projection])

      assert_raise ArgumentError, ~r/проекция await_account_only не из projections:/, fn ->
        AccountOnly.await(Account, Account.ID.new(), 100)
      end
    end
  end

  describe "span" do
    setup do
      :ok = OtelFixture.attach()
      :ok
    end

    test "await <имя> — внутри трейса вызывающего, с типом и id агрегата" do
      mark!([@projection], await: :inline)
      account = Account.ID.new()
      write!(@account_repo, account, [open("Счёт")])
      _spans = OtelFixture.drain(0)

      Otel.span("usecase", [], fn ->
        assert :ok = @projection.await(Account, account, 1_000)
      end)

      spans = OtelFixture.drain()
      await = OtelFixture.find(spans, "await es_fixture")

      assert await.kind == :internal
      assert await.parent_span_id == OtelFixture.find(spans, "usecase").span_id
      assert await.status == :undefined

      assert await.attributes == %{
               "core.es.projection.name" => "es_fixture",
               "core.es.aggregate.type" => "account",
               "core.es.aggregate.id" => dump(account)
             }
    end

    test ":projection_rebuilding и :projection_timeout — record_error/1" do
      mark!([@projection])
      account = Account.ID.new()
      write!(@account_repo, account, [open("Счёт")])
      _spans = OtelFixture.drain(0)

      assert {:error, _error} = @projection.await(Account, account, 30_000)

      rebuilding = OtelFixture.drain() |> OtelFixture.find("await es_fixture")
      assert rebuilding.attributes["error.type"] == "es/projection_rebuilding"
      assert {:error, _message} = rebuilding.status

      assert :ok = Es.Projection.Test.run_until_idle(@projection)
      write!(@account_repo, account, [close()])
      _spans = OtelFixture.drain(0)

      assert {:error, _error} = @projection.await(Account, account, 10)

      timeout = OtelFixture.drain() |> OtelFixture.find("await es_fixture")
      assert timeout.attributes["error.type"] == "es/projection_timeout"
      assert {:error, _message} = timeout.status
    end
  end

  defp mark!(projections, opts \\ []) do
    :ignore =
      Es.Projection.Supervisor.start_link([projections: projections, enabled: false] ++ opts)

    :ok
  end

  defp start_tree!(projections, opts \\ []) do
    opts = [projections: projections, enabled: true] ++ @quiet ++ opts
    {:ok, _pid} = start_supervised({Es.Projection.Supervisor, opts})
    :ok
  end

  defp insert_entity!(id, name) do
    event = EventFixture.in_stream(EventFixture.created(name), id, 1)
    {:ok, _entity} = @entity_repo.insert(entity(id, 1, name, [event]), Context.new())
    :ok
  end

  defp close_entity!(id, name) do
    event = EventFixture.in_stream(EventFixture.closed(), id, 2)
    {:ok, _entity} = @entity_repo.update(entity(id, 2, name, [event]), Context.new())
    :ok
  end

  defp entity(id, version, name, events) do
    %Entity{
      id: id,
      version: Version.new!(version),
      name: name,
      children: %{},
      events: Es.Events.new(events)
    }
  end

  defp rows do
    from(r in EsFixture.Projection.Row,
      order_by: [r.aggregate_type],
      select: {r.aggregate_type, r.aggregate_id, r.name, r.closed}
    )
    |> TestRepo.all()
  end

  # Блокировку пачки держит транзакция другого соединения до конца теста.
  defp hold_batch_lock!(projection) do
    test = self()

    holder = spawn(fn -> Sandbox.unboxed_run(TestRepo, fn -> hold_lock(projection, test) end) end)

    on_exit(fn ->
      ref = Process.monitor(holder)
      send(holder, :release)
      assert_receive {:DOWN, ^ref, :process, ^holder, _reason}
    end)

    assert_receive :batch_locked
    :ok
  end

  defp hold_lock(projection, test) do
    TestRepo.transaction(fn ->
      true = Es.Projection.Checkpoint.try_lock(projection.__es_projection__())
      send(test, :batch_locked)

      receive do
        :release -> :ok
      end
    end)
  end

  # Событие потока, закоммиченное другим соединением в обход sandbox; строку убирает `on_exit`.
  defp commit_event!(account) do
    row = event_row(account)

    in_other_connection(fn -> {1, nil} = TestRepo.insert_all(Es.Store.Schema, [row]) end)

    on_exit(fn ->
      in_other_connection(fn ->
        TestRepo.delete_all(from(e in Es.Store.Schema, where: e.aggregate_id == ^row.aggregate_id))
      end)
    end)

    :ok
  end

  # Первое событие потока счёта; тег проекция пропускает, но чекпоинт через него проходит.
  defp event_row(account) do
    %{
      aggregate_type: "account",
      aggregate_id: dump(account),
      aggregate_version: 1,
      event_id: dump(Es.Event.ID.new()),
      tag: "account.frozen",
      payload: nil,
      by_id: dump(EsFixture.UserID.new()),
      at: DateTime.utc_now(:second)
    }
  end

  defp in_other_connection(fun) do
    Task.async(fn -> Sandbox.unboxed_run(TestRepo, fun) end)
    |> Task.await()
  end

  # Чтения строки чекпоинта процессом теста за время `fun`.
  defp count_checkpoint_reads(fun) do
    test = self()
    ref = make_ref()
    :ok = on_query("FROM es_checkpoints", fn -> send(test, {ref, :read}) end)
    {fun.(), drain_reads(ref, 0)}
  end

  defp drain_reads(ref, count) do
    receive do
      {^ref, :read} -> drain_reads(ref, count + 1)
    after
      0 -> count
    end
  end

  # `fun` в отдельном процессе после первого чтения строки чекпоинта процессом теста: ожидание уже
  # подписано на сигнал и застало чекпоинт отстающим.
  defp after_checkpoint_read(fun) do
    ref = make_ref()

    task =
      Task.async(fn ->
        receive do
          ^ref -> fun.()
        end
      end)

    :ok = on_query("FROM es_checkpoints", fn -> send(task.pid, ref) end)
    task
  end

  # `fun` в процессе теста после каждого его запроса с `fragment` в тексте — до конца теста.
  defp on_query(fragment, fun) do
    test = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:core, :test_repo, :query],
        fn _event, _measurements, %{query: query}, _config ->
          if self() == test and String.contains?(query, fragment), do: fun.()
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  # Mailbox теста без telemetry ожидания и цикла читателя: всё прочее — сигналы, оставленные await/3.
  defp leftovers do
    {:messages, messages} = Process.info(self(), :messages)

    Enum.reject(
      messages,
      &match?({event, _metadata, _measurements} when event in ~w(await cycle)a, &1)
    )
  end

  defp insert_checkpoint!(name, version) do
    sql = "INSERT INTO es_checkpoints (name, version) VALUES ($1, $2)"
    %Postgrex.Result{num_rows: 1} = TestRepo.query!(sql, [name, version])
    :ok
  end

  defp delete_checkpoint!(name) do
    sql = "DELETE FROM es_checkpoints WHERE name = $1"
    %Postgrex.Result{num_rows: 1} = TestRepo.query!(sql, [name])
    :ok
  end
end
