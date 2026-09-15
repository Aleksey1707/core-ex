defmodule Core.Es.Projection.AwaitCommitTest do
  # Видимость события пачке держит транзакция другого соединения, а sandbox-транзакция теста одна на
  # всех: участники и процессы дерева коммитят по-настоящему. Отсюда `async: false`, режим sandbox
  # `:auto` на время модуля и очистка таблиц после теста.
  use ExUnit.Case, async: false

  import Core.EsAggregateRepoContract, only: [dump: 1, open: 1, write!: 3]
  import Ecto.Query, only: [from: 2]

  alias Core.Config
  alias Core.Es
  alias Core.EsFixture
  alias Core.EsFixture.Account
  alias Core.Helper.Transact
  alias Core.Telemetry
  alias Core.TestRepo
  alias Ecto.Adapters.SQL.Sandbox

  require Config

  @projection EsFixture.Projection
  @account_repo Config.repo!(Account.Repo)
  @quiet [
    idle_min_ms: 60_000,
    poll_interval_ms: 60_000,
    retry_min_ms: 60_000,
    retry_max_ms: 60_000
  ]
  @distant_steps [await_min_ms: 60_000, await_max_ms: 60_000]
  @timeout 5_000

  setup_all do
    :ok = Sandbox.mode(TestRepo, :auto)
    on_exit(fn -> Sandbox.mode(TestRepo, :manual) end)
  end

  setup do
    handler_id = "es-projection-await-commit-#{inspect(self())}"

    :ok =
      :telemetry.attach(
        handler_id,
        Telemetry.event([:es, :projection, :cycle]),
        fn _event, _measurements, metadata, test_pid -> send(test_pid, {:cycle, metadata}) end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    on_exit(fn -> :persistent_term.erase(Es.Projection.Supervisor.Mark) end)

    on_exit(fn ->
      # Репозиторий счёта пишет запись outbox в транзакции append.
      TestRepo.query!("TRUNCATE es_events, outbox, es_checkpoints, fixture_projection_streams")
    end)
  end

  test "старая пишущая транзакция держала событие за пачкой — после её commit шаг ожидания будит читателя" do
    # Строка чекпоинта до дерева: без неё ожидание отдало бы пересборку.
    assert :ok = Es.Projection.Test.run_until_idle(@projection)
    start_tree!([@projection])
    older = participant()

    assert %Postgrex.Result{} =
             step(older, fn -> TestRepo.query!("SELECT pg_current_xact_id()") end)

    account = Account.ID.new()

    write!(@account_repo, account, [open("Счёт")])

    assert_receive {:cycle, %{projection: "es_fixture", result: :idle}}, @timeout
    assert :ok = commit(older)

    assert :ok = Es.Projection.await(@projection, Account, account, @timeout)
    assert rows() == [{"account", dump(account), "Счёт", false}]
  end

  test "пачку прогнало другое соединение — уведомление канала через слушателя, :ok без шага ожидания" do
    assert :ok = Es.Projection.Test.run_until_idle(@projection)
    account = Account.ID.new()
    # Дерева ещё нет: `append` читателя не будит.
    write!(@account_repo, account, [open("Счёт")])
    since = db_now()
    start_tree!([@projection], @distant_steps)
    :ok = await_listening(since)

    # Пачка другого соединения — после того, как ожидание застало чекпоинт отстающим: читатель
    # спит 60 000 мс, шаг ожидания тоже, и `:ok` приносит только уведомление канала.
    batch = after_checkpoint_read(fn -> Es.Projection.run_once(@projection) end)

    assert :ok = Es.Projection.await(@projection, Account, account, @timeout)
    assert :processed = Task.await(batch)
    assert rows() == [{"account", dump(account), "Счёт", false}]
  end

  test "notifications: false — :ok сигналом читателя внутри ноды" do
    assert :ok = Es.Projection.Test.run_until_idle(@projection)
    tree = start_tree!([@projection], [notifications: false] ++ @distant_steps)
    refute List.keymember?(Supervisor.which_children(tree), :listeners, 0)
    reader = Process.whereis(@projection)
    account = Account.ID.new()

    # `wake` записи ждёт в очереди читателя, пока ожидание не застало чекпоинт отстающим.
    :ok = :sys.suspend(reader)
    write!(@account_repo, account, [open("Счёт")])
    resumed = after_checkpoint_read(fn -> :sys.resume(reader) end)

    assert :ok = Es.Projection.await(@projection, Account, account, @timeout)
    assert :ok = Task.await(resumed)
    assert rows() == [{"account", dump(account), "Счёт", false}]
  end

  describe "канал core_es_checkpoint" do
    test "notifications: false — пачка не шлёт уведомление ни при старте с начала, ни при сдвиге" do
      listening = listen!()
      :ok = mark!(notifications: false)

      assert :processed = Es.Projection.run_once(@projection)
      write!(@account_repo, Account.ID.new(), [open("Счёт")])
      assert :processed = Es.Projection.run_once(@projection)

      # Уведомления канала приходят в порядке коммитов: метка первой — пачки в канал не слали.
      :ok = notify!("метка")
      assert next_notification(listening) == "метка"
    end

    test "отметки нет или notifications: true — пачка шлёт имя проекции, append — нет" do
      listening = listen!()

      assert :processed = Es.Projection.run_once(@projection)
      assert next_notification(listening) == "es_fixture"

      :ok = mark!(notifications: true)
      write!(@account_repo, Account.ID.new(), [open("Счёт")])
      :ok = notify!("метка")
      assert next_notification(listening) == "метка"

      assert :processed = Es.Projection.run_once(@projection)
      assert next_notification(listening) == "es_fixture"
    end
  end

  defp start_tree!(projections, opts \\ []) do
    opts = [projections: projections, enabled: true] ++ @quiet ++ opts
    {:ok, pid} = start_supervised({Es.Projection.Supervisor, opts})
    pid
  end

  defp db_now do
    %Postgrex.Result{rows: [[now]]} = TestRepo.query!("SELECT clock_timestamp()")
    now
  end

  # Слушатель дерева соединяется после старта, а уведомление до его `LISTEN` теряется: ждать
  # соединение, открытое после `since` и выполнившее `LISTEN`.
  defp await_listening(since) do
    sql =
      "SELECT 1 FROM pg_stat_activity WHERE datname = current_database() " <>
        "AND backend_start >= $1 AND state = 'idle' AND query LIKE '%LISTEN \"core_es_checkpoint\"%'"

    case TestRepo.query!(sql, [since]) do
      %Postgrex.Result{num_rows: 0} -> await_listening(since)
      %Postgrex.Result{} -> :ok
    end
  end

  # `fun` в отдельном процессе после первого чтения строки чекпоинта процессом теста: ожидание уже
  # подписано на сигнал и застало чекпоинт отстающим.
  defp after_checkpoint_read(fun) do
    test = self()
    ref = make_ref()

    task =
      Task.async(fn ->
        receive do
          ^ref -> fun.()
        end
      end)

    handler = {__MODULE__, ref}

    :ok =
      :telemetry.attach(
        handler,
        [:core, :test_repo, :query],
        fn _event, _measurements, %{query: query}, _config ->
          if self() == test and String.contains?(query, "FROM es_checkpoints"),
            do: send(task.pid, ref)
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    task
  end

  # Участник держит свою транзакцию и исполняет присланные шаги по одному, пока не получит `:commit`.
  defp participant do
    test = self()

    Task.async(fn -> Transact.run(TestRepo, fn -> serve(test) end) end)
  end

  defp serve(test) do
    receive do
      {:step, fun} ->
        send(test, {:step, self(), fun.()})
        serve(test)

      :commit ->
        :ok
    end
  end

  defp step(%Task{pid: pid}, fun) do
    send(pid, {:step, fun})
    assert_receive {:step, ^pid, result}, @timeout
    result
  end

  defp commit(%Task{pid: pid} = participant) do
    send(pid, :commit)
    Task.await(participant, @timeout)
  end

  defp mark!(opts) do
    :ignore =
      Es.Projection.Supervisor.start_link([projections: [@projection], enabled: false] ++ opts)

    :ok
  end

  # Тест слушает канал сам: с синхронным соединением `listen/3` отвечает после `LISTEN`.
  defp listen! do
    {:ok, pid} = start_supervised({Postgrex.Notifications, TestRepo.config()})
    {:ok, ref} = Postgrex.Notifications.listen(pid, "core_es_checkpoint", timeout: @timeout)
    ref
  end

  defp notify!(payload) do
    sql = "SELECT pg_notify('core_es_checkpoint', $1)"
    %Postgrex.Result{num_rows: 1} = TestRepo.query!(sql, [payload])
    :ok
  end

  defp next_notification(listening) do
    assert_receive {:notification, _pid, ^listening, "core_es_checkpoint", payload}, @timeout
    payload
  end

  defp rows do
    from(r in EsFixture.Projection.Row,
      select: {r.aggregate_type, r.aggregate_id, r.name, r.closed}
    )
    |> TestRepo.all()
  end
end
