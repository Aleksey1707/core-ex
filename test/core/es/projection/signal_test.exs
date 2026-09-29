defmodule Core.Es.Projection.SignalTest do
  # Уведомление канала доставляется только после настоящего commit, а sandbox-транзакция теста одна
  # на всех: процессы дерева коммитят по-настоящему. Отсюда `async: false`, режим sandbox `:auto` на
  # время модуля и очистка таблиц после теста.
  use ExUnit.Case, async: false

  import Core.EsAggregateRepoContract, only: [open: 1, rename: 1, write!: 3]

  alias Core.Config
  alias Core.Es
  alias Core.EsFixture
  alias Core.EsFixture.Account
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
  @timeout 5_000

  setup_all do
    :ok = Sandbox.mode(TestRepo, :auto)
    on_exit(fn -> Sandbox.mode(TestRepo, :manual) end)
  end

  setup do
    handler_id = "es-projection-signal-#{inspect(self())}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          Telemetry.event([:es, :projection, :signal, :sent]),
          Telemetry.event([:es, :projection, :signal, :received]),
          Telemetry.event([:es, :projection, :cycle])
        ],
        fn event, measurements, metadata, test_pid ->
          send(test_pid, {List.last(event), measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    on_exit(fn -> :persistent_term.erase(Es.Projection.Supervisor.Mark) end)

    on_exit(fn ->
      TestRepo.query!(
        "TRUNCATE es_events, outbox, es_checkpoints, fixture_projection_streams, " <>
          "fixture_broken_projection_streams, fixture_broken_projection_names"
      )
    end)
  end

  test "старт слушателя засевает sent и received нулём со своим repo" do
    start_tree!([@projection])

    assert_receive {:sent, %{count: 0}, %{repo: TestRepo}}, @timeout
    assert_receive {:received, %{count: 0}, %{repo: TestRepo}}, @timeout
  end

  test "уведомление канала core_es_checkpoint — received с count: 1 и repo слушателя" do
    since = db_now()
    start_tree!([@projection])
    :ok = await_listening(since)

    :ok = notify!("чужая_проекция")

    assert_receive {:received, %{count: 1}, %{repo: TestRepo}}, @timeout
  end

  test "закоммиченная пачка :processed читателя — sent с count: 1 и repo = dao декларации" do
    assert :ok = Es.Projection.Test.run_until_idle(@projection)
    start_tree!([@projection])

    write!(@account_repo, Account.ID.new(), [open("Счёт")])

    assert_receive {:cycle, _measurements, %{projection: "es_fixture", result: :processed}}, @timeout
    assert_received {:sent, %{count: 1}, %{repo: TestRepo}}
  end

  test "ручной run_once/2 — sent не засчитывается" do
    assert :processed = Es.Projection.run_once(@projection)

    refute_received {:sent, _measurements, _metadata}
  end

  test "notifications: false — ни засева, ни sent на пачку" do
    assert :ok = Es.Projection.Test.run_until_idle(@projection)
    start_tree!([@projection], notifications: false)

    write!(@account_repo, Account.ID.new(), [open("Счёт")])

    assert_receive {:cycle, _measurements, %{projection: "es_fixture", result: :processed}}, @timeout
    refute_received {:sent, _measurements, _metadata}
    refute_received {:received, _measurements, _metadata}
  end

  @tag :capture_log
  test "откатившаяся пачка sent не эмитит" do
    projection = EsFixture.BrokenProjection
    assert :ok = Es.Projection.Test.run_until_idle(projection)

    # Команды пишутся отдельными `append`: до дерева, чтобы открытие не ушло своей пачкой.
    # `project/1` на переименовании падает — пачка откатывается вместе с открытием.
    write!(@account_repo, Account.ID.new(), [open("Счёт"), rename("Другой")])
    start_tree!([projection], idle_min_ms: 10)

    assert_receive {:cycle, _measurements, %{projection: "es_fixture_broken", result: :retry}}, @timeout
    refute_received {:sent, %{count: 1}, _metadata}
  end

  defp start_tree!(projections, opts \\ []) do
    opts = [projections: projections, enabled: true] ++ opts ++ @quiet
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

  defp notify!(payload) do
    sql = "SELECT pg_notify('core_es_checkpoint', $1)"
    %Postgrex.Result{num_rows: 1} = TestRepo.query!(sql, [payload])
    :ok
  end
end
