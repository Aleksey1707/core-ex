defmodule Core.Es.Aggregate.ReadRepo.SnapshottedTest do
  use Core.DataCase, async: true

  use Core.EsAggregateReadRepoContract,
    impl: Core.EsFixture.Account.AtVersion.Snapshotted.ReadRepo.Pg,
    repo: Core.EsFixture.Account.Repo.Pg,
    error_module: Core.EsFixture.Account.Repo.Snapshotted,
    snapshot: :miss

  alias Core.Config
  alias Core.Es.Aggregate.Repo.Pg.Snapshot
  alias Core.EsFixture.Account
  alias Core.EsFixture.Account.AtVersion.View
  alias Core.EsFixture.UserID
  alias Core.Telemetry

  @write_repo Account.Repo.Snapshotted.Pg
  @read_repo Account.AtVersion.Snapshotted.ReadRepo.Pg

  describe "снапшоты" do
    test "снапшот не выше версии — начало свёртки, хвост от снапшота" do
      id = Account.ID.new()
      state = write!(@write_repo, id, [open("Первое"), rename("Второе")])
      assert {:ok, _state} = @write_repo.get(id, :current, Context.new())
      append!(state, [freeze()])
      attach_telemetry()

      assert {:ok, %View{version: 3, name: "Второе", status: "frozen", holder: nil}} =
               @read_repo.get_at(id, Version.new!(3), Context.new())

      assert_received {:telemetry, [:core, :es, :aggregate, :fold], %{events: 1}, %{type: "account", snapshot: :hit}}
    end

    test "снапшот новее версии — поток с начала" do
      id = Account.ID.new()
      append!(%Account{id: id}, [open("Первое"), rename("Второе"), freeze()])
      assert {:ok, _state} = @write_repo.get(id, :current, Context.new())
      attach_telemetry()

      assert {:ok, %View{version: 2, name: "Второе", status: "open", holder: nil}} =
               @read_repo.get_at(id, Version.new!(2), Context.new())

      assert_received {:telemetry, [:core, :es, :aggregate, :fold], %{events: 2}, %{type: "account", snapshot: :miss}}
    end

    test "чтение не меняет снапшот и не пишет его, даже когда хвост длиннее every" do
      id = Account.ID.new()
      state = append!(%Account{id: id}, [open("Первое"), rename("Второе")])
      assert {:ok, _state} = @write_repo.get(id, :current, Context.new())
      before = snapshot(id)
      assert %Snapshot.Schema{aggregate_version: 2} = before
      append!(state, [freeze(), Core.EsAggregateRepoContract.close()])
      attach_telemetry()

      assert {:ok, %View{version: 4, name: "Второе", status: "closed"}} =
               @read_repo.get_at(id, Version.new!(4), Context.new())

      assert snapshot(id) == before
      refute_received {:telemetry, [:core, :es, :snapshot, :write], _measurements, _metadata}
      assert_received {:telemetry, [:core, :es, :aggregate, :fold], %{events: 2}, %{type: "account", snapshot: :hit}}
    end

    test "зашифрованный снапшот ПДн — как get до и после уничтожения ключа" do
      id = Account.ID.new()
      write!(@write_repo, id, [open("Первый"), set_holder("Иван Петров")])
      assert {:ok, _state} = @write_repo.get(id, :current, Context.new())
      assert %Snapshot.Schema{} = before = snapshot(id)

      assert {:ok, state} = @write_repo.get(id, Version.new!(2), Context.new())
      expected = View.from_state(state)
      assert {:ok, ^expected} = @read_repo.get_at(id, Version.new!(2), Context.new())

      assert :ok = Personal.destroy_key(id, UserID.new(), Context.new())
      assert {:ok, destroyed} = @write_repo.get(id, Version.new!(2), Context.new())
      expected = View.from_state(destroyed)
      assert %{holder: %{destroyed: true}} = expected
      attach_telemetry()

      assert {:ok, ^expected} = @read_repo.get_at(id, Version.new!(2), Context.new())
      assert snapshot(id) == before
      refute_received {:telemetry, [:core, :es, :snapshot, :write], _measurements, _metadata}
    end

    test "чтение вне транзакции с опциями запроса" do
      id = Account.ID.new()
      write!(@write_repo, id, [open("Первое"), rename("Второе")])

      assert {:ok, %View{version: 2, name: "Второе"}} =
               @read_repo.get_at(id, Version.new!(2), Context.new(), timeout: 5_000, log: false)
    end
  end

  def handle_telemetry(event, measurements, metadata, test) do
    if self() == test, do: send(test, {:telemetry, event, measurements, metadata})
  end

  defp attach_telemetry do
    handler = {__MODULE__, make_ref()}

    events = [
      Telemetry.event([:es, :aggregate, :fold]),
      Telemetry.event([:es, :snapshot, :write])
    ]

    :ok = :telemetry.attach_many(handler, events, &__MODULE__.handle_telemetry/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp append!(state, commands) do
    Enum.reduce(commands, state, fn command, state ->
      {events, next} = Core.EsAggregateRepoContract.execute!(state, command)
      :ok = @write_repo.append(events, Context.new())
      next
    end)
  end

  defp snapshot(id),
    do: Config.dao().get_by(Snapshot.Schema, aggregate_type: "account", aggregate_id: dump(id))
end
