defmodule Core.Es.Aggregate.Repo.Pg.SnapshottedTest do
  use Core.DataCase, async: true
  use Core.EsAggregateRepoContract, impl: Core.EsFixture.Account.Repo.Pg.Snapshotted

  import ExUnit.CaptureLog

  alias Core.Config
  alias Core.Context
  alias Core.Es.Aggregate.Repo.Pg.Snapshot
  alias Core.EsFixture.Account
  alias Core.Helper.Transact
  alias Core.Telemetry

  @repo Account.Repo.Pg.Snapshotted

  defmodule FailingDao do
    @moduledoc false

    defdelegate all(query, opts), to: Core.TestRepo

    def insert_all(_schema, _rows, _opts),
      do: raise(DBConnection.ConnectionError, "соединение потеряно")
  end

  defmodule FailingRepo do
    @moduledoc false

    use Core.Es.Aggregate.Repo.Pg,
      behaviour: Core.EsFixture.Account.Repo,
      aggregate: Core.EsFixture.Account,
      id: Core.EsFixture.Account.ID,
      errors: Core.EsFixture.Account.Errors,
      outbox: Core.EsFixture.Account.Outbox,
      repo: Core.Es.Aggregate.Repo.Pg.SnapshottedTest.FailingDao,
      snapshot: [every: 1]
  end

  describe "запись снапшота" do
    test "свёрнуто меньше every — снапшота нет" do
      id = Account.ID.new()
      write!(@repo, id, [open()])

      assert {:ok, _state} = @repo.get(id, :current, Context.new())
      assert snapshot(id) == nil
    end

    test "свёрнуто не меньше every — снапшот на голове потока" do
      id = Account.ID.new()
      state = write!(@repo, id, [open(), freeze()])
      attach_telemetry()

      assert {:ok, ^state} = @repo.get(id, :current, Context.new())

      assert %Snapshot.Schema{aggregate_version: 2} = snapshot(id)

      assert_received {:telemetry, [:core, :es, :snapshot, :write], %{duration: _, rows: 1},
                       %{type: "account", result: :ok}}
    end

    test "в транзакции — после commit; откат — без снапшота" do
      id = Account.ID.new()
      state = write!(@repo, id, [open(), freeze()])

      assert {:error, :rollback} =
               Transact.run(Config.dao(), fn ->
                 assert {:ok, ^state} = @repo.get(id, :current, Context.new())
                 {:error, :rollback}
               end)

      assert snapshot(id) == nil

      assert :ok =
               Transact.run(Config.dao(), fn ->
                 assert {:ok, ^state} = @repo.get(id, :current, Context.new())
                 assert snapshot(id) == nil
                 :ok
               end)

      assert %Snapshot.Schema{aggregate_version: 2} = snapshot(id)
    end

    test "get_many — один upsert на все потоки" do
      ids = for _ <- 1..3, do: Account.ID.new()
      Enum.each(ids, &write!(@repo, &1, [open(), freeze()]))

      assert {{:ok, [_, _, _]}, 1} =
               count_queries(
                 fn -> @repo.get_many(Enum.map(ids, &{&1, :current}), Context.new()) end,
                 :insert
               )

      assert Enum.map(ids, &snapshot(&1).aggregate_version) == [2, 2, 2]
    end

    test "refresh пишет по тому же правилу" do
      id = Account.ID.new()
      state = write!(@repo, id, [open(), freeze()])

      assert {:ok, ^state} = @repo.refresh(%Account{id: id}, :current, Context.new())
      assert %Snapshot.Schema{aggregate_version: 2} = snapshot(id)
    end

    test "снапшот более поздней версии не перетирается" do
      id = Account.ID.new()
      state = write!(@repo, id, [open(), freeze()])
      assert {:ok, _state} = @repo.get(id, :current, Context.new())
      update_snapshot!(id, aggregate_version: 10)

      capture_log(fn -> assert {:ok, ^state} = @repo.get(id, :current, Context.new()) end)

      assert %Snapshot.Schema{aggregate_version: 10} = snapshot(id)
    end

    test "отказ записи — warning, состояние отдано" do
      id = Account.ID.new()
      state = write!(@repo, id, [open()])
      attach_telemetry()

      log =
        capture_log(fn ->
          assert {:ok, ^state} = FailingRepo.get(id, :current, Context.new())
        end)

      assert log =~ "снапшоты агрегата не записаны: type=account rows=1"
      assert log =~ "соединение потеряно"

      assert_received {:telemetry, [:core, :es, :snapshot, :write], %{rows: 0}, %{type: "account", result: :error}}
    end
  end

  describe "чтение от снапшота" do
    test "свёртка хвоста после снапшота" do
      id = Account.ID.new()
      write!(@repo, id, [open(), freeze()])
      assert {:ok, _state} = @repo.get(id, :current, Context.new())
      closed = write!(@repo, id, [close()])
      attach_telemetry()

      assert {{:ok, ^closed}, 1} =
               count_queries(fn -> @repo.get(id, :current, Context.new()) end, :select)

      assert_received {:telemetry, [:core, :es, :aggregate, :fold], %{events: 1}, %{type: "account", snapshot: :hit}}

      assert_received {:telemetry, [:core, :es, :aggregate, :load],
                       %{
                         streams: 1,
                         events: 1,
                         snapshot_hit: 1,
                         snapshot_miss: 0,
                         snapshot_rejected: 0
                       }, %{op: :get, result: :ok}}
    end

    test "%Version{} сверяется с головой после свёртки от снапшота" do
      id = Account.ID.new()
      write!(@repo, id, [open(), freeze()])
      assert {:ok, _state} = @repo.get(id, :current, Context.new())
      write!(@repo, id, [close()])

      assert {:error, %Core.Error{code: :version_mismatch} = error} =
               @repo.get(id, Core.Version.new!(2), Context.new())

      assert error.detail == %{aggregate_id: dump(id), expected: 2, actual: 3, source: :expected}
    end

    test "маркер не совпал — полная свёртка тем же запросом без warning" do
      id = Account.ID.new()
      state = write!(@repo, id, [open(), freeze()])
      assert {:ok, _state} = @repo.get(id, :current, Context.new())
      update_snapshot!(id, marker: "stale")
      attach_telemetry()

      log =
        capture_log(fn ->
          assert {{:ok, ^state}, 1} =
                   count_queries(fn -> @repo.get(id, :current, Context.new()) end, :select)
        end)

      refute log =~ dump(id)

      assert_received {:telemetry, [:core, :es, :aggregate, :fold], %{events: 2}, %{snapshot: :miss}}

      assert_received {:telemetry, [:core, :es, :aggregate, :load], %{snapshot_miss: 1}, _}
      assert snapshot(id).marker != "stale"
    end

    test "битый bytea — warning и весь поток вторым запросом" do
      id = Account.ID.new()
      state = write!(@repo, id, [open(), freeze()])
      assert {:ok, _state} = @repo.get(id, :current, Context.new())
      update_snapshot!(id, state: <<131, 0, 1>>)
      attach_telemetry()

      log =
        capture_log(fn ->
          assert {{:ok, ^state}, 2} =
                   count_queries(fn -> @repo.get(id, :current, Context.new()) end, :select)
        end)

      assert log =~ "снапшот агрегата отвергнут: type=account aggregate_id=#{dump(id)}"
      assert log =~ "reason=decode"

      assert_received {:telemetry, [:core, :es, :aggregate, :fold], %{events: 2}, %{snapshot: :rejected}}

      assert_received {:telemetry, [:core, :es, :aggregate, :load], %{events: 2, snapshot_rejected: 1}, _}
    end

    test "лишний ключ struct — warning и верное состояние" do
      id = Account.ID.new()
      state = write!(@repo, id, [open(), freeze()])
      assert {:ok, _state} = @repo.get(id, :current, Context.new())
      update_snapshot!(id, state: :erlang.term_to_binary(Map.put(state, :owner, nil)))

      log =
        capture_log(fn ->
          assert {:ok, ^state} = @repo.get(id, :current, Context.new())
        end)

      assert log =~ "снапшот агрегата отвергнут: type=account aggregate_id=#{dump(id)}"
      assert log =~ "reason=struct"
    end

    test "get_many — снапшоты и полная свёртка в одном вызове, порядок пар" do
      [hit, rejected, empty] = [Account.ID.new(), Account.ID.new(), Account.ID.new()]
      hit_state = write!(@repo, hit, [open("Первый"), freeze()])
      rejected_state = write!(@repo, rejected, [open("Второй"), rename("Третий")])
      pairs = [{rejected, :current}, {empty, :current}, {hit, :current}]
      assert {:ok, _states} = @repo.get_many(pairs, Context.new())
      update_snapshot!(rejected, state: <<131, 0, 1>>)
      attach_telemetry()

      capture_log(fn ->
        assert {:ok, [^rejected_state, %Account{id: ^empty, version: nil}, ^hit_state]} =
                 @repo.get_many(pairs, Context.new())
      end)

      assert_received {:telemetry, [:core, :es, :aggregate, :load],
                       %{streams: 3, snapshot_hit: 1, snapshot_miss: 1, snapshot_rejected: 1}, %{op: :get_many}}
    end
  end

  def handle_telemetry(event, measurements, metadata, test) do
    if self() == test, do: send(test, {:telemetry, event, measurements, metadata})
  end

  defp attach_telemetry do
    handler = {__MODULE__, make_ref()}

    events = [
      Telemetry.event([:es, :aggregate, :load]),
      Telemetry.event([:es, :aggregate, :fold]),
      Telemetry.event([:es, :snapshot, :write])
    ]

    :ok = :telemetry.attach_many(handler, events, &__MODULE__.handle_telemetry/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp snapshot(id),
    do: Config.dao().get_by(Snapshot.Schema, aggregate_type: "account", aggregate_id: dump(id))

  defp update_snapshot!(id, set) do
    {1, nil} =
      from(sn in Snapshot.Schema,
        where: sn.aggregate_type == "account" and sn.aggregate_id == ^dump(id)
      )
      |> Config.dao().update_all(set: set)

    :ok
  end
end
