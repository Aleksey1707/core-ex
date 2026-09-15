defmodule Core.Es.PromExTest do
  # Подмена `:dao` и отметка процесса агрегата — глобальное состояние ноды; строки `es_events` и
  # `es_checkpoints` — в sandbox-транзакции теста.
  use Core.DataCase, async: false

  import Core.EsAggregateRepoContract, only: [dump: 1]
  import ExUnit.CaptureLog

  alias Core.Es
  alias Core.Es.PromEx
  alias Core.EsFixture
  alias Core.EsFixture.Account

  @projections {__MODULE__, :projections, []}
  @processes {__MODULE__, :processes, []}
  @now ~U[2026-09-14 12:00:00Z]

  @poll_events [
    [:prom_ex, :plugin, :es, :projection, :lag],
    [:prom_ex, :plugin, :es, :projection, :rebuilding],
    [:prom_ex, :plugin, :es, :projection, :outdated],
    [:prom_ex, :plugin, :es, :checkpoint, :orphan],
    [:prom_ex, :plugin, :es, :aggregate, :processes]
  ]

  defmodule AccountOnly do
    @moduledoc false

    use Core.Es.Projection,
      name: "prom_ex_account_only",
      events: [Core.EsFixture.Account.Event.Opened],
      version: 2

    @impl true
    def project(_event), do: :ok

    @impl true
    def clear, do: :ok
  end

  defmodule DownDao do
    @moduledoc false

    # Пул не поднят: запрос — исключение, как при недоступной БД.
    use Ecto.Repo,
      otp_app: :core,
      adapter: Ecto.Adapters.Postgres
  end

  def projections, do: [projections: [EsFixture.Projection, AccountOnly], enabled: false]

  def processes, do: [Account.Process]

  setup do
    handler_id = "es-prom-ex-#{inspect(self())}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        @poll_events,
        fn event, measurements, metadata, test_pid ->
          send(test_pid, {List.last(event), metadata, measurements})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  describe "группы метрик" do
    test "event-группы — всегда; без projections: и processes: polling-групп нет" do
      opts = [otp_app: :core]

      names = metric_names(PromEx.event_metrics(opts))

      for name <- ~w(
            aggregate.load.total
            aggregate.load.duration.milliseconds
            aggregate.fold.events
            snapshot.write.total
            snapshot.write.duration.milliseconds
            snapshot.write.rows.total
            projection.cycles.total
            projection.duration.milliseconds
            projection.events.total
            projection.retry.total
            projection.await.total
            projection.await.duration.milliseconds
            aggregate.process.execute.total
            aggregate.process.execute.duration.milliseconds
            aggregate.process.execute.queue.milliseconds
            aggregate.process.execute.retries.total
            aggregate.process.start.total
            aggregate.process.stop.total
          ) do
        assert ("core.prom_ex.es." <> name) in names
      end

      assert PromEx.polling_metrics(opts) == []
    end

    test "projections: и processes: — polling-группы проекций и процессов с poll_rate" do
      opts = [otp_app: :core, poll_rate: 1_000, projections: @projections, processes: @processes]

      assert [%{poll_rate: 1_000} = projection_group, %{poll_rate: 1_000} = process_group] =
               PromEx.polling_metrics(opts)

      assert metric_names([projection_group]) == [
               "core.prom_ex.es.projection.lag.seconds",
               "core.prom_ex.es.projection.rebuilding",
               "core.prom_ex.es.projection.outdated",
               "core.prom_ex.es.checkpoint.orphan"
             ]

      assert metric_names([process_group]) == ["core.prom_ex.es.aggregate.processes"]
    end

    test "retry.total — только циклы :retry, с меткой error" do
      metric = metric!(PromEx.event_metrics(otp_app: :core), "projection.retry.total")

      refute metric.keep.(%{projection: "account_list", result: :idle})
      assert metric.keep.(%{projection: "account_list", result: :retry, error: "fake/failed"})
      assert metric.tags == [:projection, :error]
    end
  end

  describe "отставание проекции" do
    test "строки чекпоинта нет — возраст первого события истории типов проекции" do
      insert_event!("fixture", 300)
      insert_event!("account", 200)
      insert_event!("account", 100)

      PromEx.execute_projection_metrics(@projections, @now)

      assert_receive {:lag, %{projection: "es_fixture"}, %{seconds: 300}}
      assert_receive {:lag, %{projection: "prom_ex_account_only"}, %{seconds: 200}}
    end

    test "события после чекпоинта — возраст первого из них; события других типов не в счёт" do
      first = insert_event!("account", 200)
      insert_event!("fixture", 300)
      insert_event!("account", 100)
      insert_checkpoint!("prom_ex_account_only", 2, first)

      PromEx.execute_projection_metrics(@projections, @now)

      assert_receive {:lag, %{projection: "prom_ex_account_only"}, %{seconds: 100}}
    end

    test "событий после чекпоинта нет — 0" do
      insert_event!("account", 200)
      last = insert_event!("account", 100)
      insert_checkpoint!("prom_ex_account_only", 2, last)

      PromEx.execute_projection_metrics(@projections, @now)

      assert_receive {:lag, %{projection: "prom_ex_account_only"}, %{seconds: 0}}
    end

    test "версия строки ниже version: модуля — возраст первого события истории" do
      insert_event!("account", 200)
      last = insert_event!("account", 100)
      insert_checkpoint!("prom_ex_account_only", 1, last)

      PromEx.execute_projection_metrics(@projections, @now)

      assert_receive {:lag, %{projection: "prom_ex_account_only"}, %{seconds: 200}}
    end
  end

  describe "пересборка, устаревшая нода и сироты" do
    test "строки чекпоинта нет — rebuilding 1, outdated 0" do
      PromEx.execute_projection_metrics(@projections, @now)

      assert_receive {:rebuilding, %{projection: "prom_ex_account_only"}, %{value: 1}}
      assert_receive {:outdated, %{projection: "prom_ex_account_only"}, %{value: 0}}
    end

    test "версия строки ниже version: модуля — rebuilding 1" do
      insert_checkpoint!("prom_ex_account_only", 1, {10, 5})

      PromEx.execute_projection_metrics(@projections, @now)

      assert_receive {:rebuilding, %{projection: "prom_ex_account_only"}, %{value: 1}}
      assert_receive {:outdated, %{projection: "prom_ex_account_only"}, %{value: 0}}
    end

    test "чекпоинт ниже цели пересборки — rebuilding 1, цель достигнута — 0" do
      insert_checkpoint!("prom_ex_account_only", 2, {10, 5}, {10, 9})
      insert_checkpoint!("es_fixture", 1, {10, 9}, {10, 9})

      PromEx.execute_projection_metrics(@projections, @now)

      assert_receive {:rebuilding, %{projection: "prom_ex_account_only"}, %{value: 1}}
      assert_receive {:rebuilding, %{projection: "es_fixture"}, %{value: 0}}
    end

    test "версия строки выше version: модуля на этой ноде — outdated 1, rebuilding 0" do
      insert_checkpoint!("prom_ex_account_only", 3, {10, 5})

      PromEx.execute_projection_metrics(@projections, @now)

      assert_receive {:outdated, %{projection: "prom_ex_account_only"}, %{value: 1}}
      assert_receive {:rebuilding, %{projection: "prom_ex_account_only"}, %{value: 0}}
    end

    test "строка без проекции в списке ноды — checkpoint.orphan 1, строка проекции списка — 0" do
      insert_checkpoint!("prom_ex_removed", 1)
      insert_checkpoint!("prom_ex_account_only", 2)

      PromEx.execute_projection_metrics(@projections, @now)

      assert_receive {:orphan, %{name: "prom_ex_removed"}, %{value: 1}}
      assert_receive {:orphan, %{name: "prom_ex_account_only"}, %{value: 0}}
    end

    test "недоступная БД — цикл пропущен с warning, gauges не эмитятся" do
      configured = Application.fetch_env!(:core, :dao)
      on_exit(fn -> Application.put_env(:core, :dao, configured) end)
      Application.put_env(:core, :dao, DownDao)

      log =
        capture_log(fn -> assert :ok = PromEx.execute_projection_metrics(@projections, @now) end)

      assert log =~ "сбор метрик пропущен (es projections)"
      refute_received {_gauge, _metadata, _measurements}
    end
  end

  describe "процессы агрегата" do
    test "processes{type} — процессы на id под DynamicSupervisor; дерево не запущено — 0" do
      on_exit(fn -> :persistent_term.erase({Es.Aggregate.Process, Account.Process}) end)

      PromEx.execute_process_metrics(@processes)

      assert_receive {:processes, %{type: "account"}, %{count: 0}}

      start_supervised!({Account.Process, enabled: true})

      {:ok, _pid} =
        DynamicSupervisor.start_child(Account.Process.Supervisor, {Agent, fn -> :ok end})

      PromEx.execute_process_metrics(@processes)

      assert_receive {:processes, %{type: "account"}, %{count: 1}}
    end
  end

  defp metric_names(groups),
    do: for(%{metrics: metrics} <- groups, metric <- metrics, do: Enum.join(metric.name, "."))

  defp metric!(groups, name) do
    full = "core.prom_ex.es." <> name

    [metric] =
      for %{metrics: metrics} <- groups,
          metric <- metrics,
          Enum.join(metric.name, ".") == full,
          do: metric

    metric
  end

  # Событие типа `type` с моментом `age` секунд до `@now`; позиция — по порядку вставки.
  defp insert_event!(type, age) do
    row = %{
      aggregate_type: type,
      aggregate_id: dump(Account.ID.new()),
      aggregate_version: 1,
      event_id: dump(Es.Event.ID.new()),
      tag: "prom_ex.event",
      payload: nil,
      by_id: dump(EsFixture.UserID.new()),
      at: DateTime.add(@now, -age)
    }

    {1, nil} = TestRepo.insert_all(Es.Store.Schema, [row])
    Es.Store.last_position(TestRepo, [type])
  end

  defp insert_checkpoint!(name, version, position \\ nil, target \\ nil) do
    {xid, number} = position || {nil, nil}
    {target_xid, target_number} = target || {nil, nil}

    sql =
      "INSERT INTO es_checkpoints (name, xid, number, version, target_xid, target_number) " <>
        "VALUES ($1, $2, $3, $4, $5, $6)"

    params = [name, xid, number, version, target_xid, target_number]
    %Postgrex.Result{num_rows: 1} = TestRepo.query!(sql, params)
    :ok
  end
end
