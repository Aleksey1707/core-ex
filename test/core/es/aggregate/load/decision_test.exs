defmodule Core.Es.Aggregate.Load.DecisionTest do
  use ExUnit.Case, async: true

  import Core.EsAggregateRepoContract, only: [dump: 1, execute!: 2, freeze: 0, open: 0, open: 1, rename: 1]

  alias Core.Es.Aggregate.Load.Decision
  alias Core.Es.Store.Rows
  alias Core.EsFixture.Account
  alias Core.Telemetry
  alias Core.Version

  defmodule LoadRepo do
    @moduledoc false

    use Core.Es.Aggregate.Repo.Pg,
      behaviour: Core.EsFixture.Account.Repo,
      errors: Core.EsFixture.Account.Errors,
      outbox: Core.EsFixture.Account.Outbox,
      snapshot: [every: 2]

    def cfg, do: es_aggregate_repo()
  end

  describe "голова" do
    test "решение над состоянием головы потока" do
      id = Account.ID.new()
      events = events!(id, [open("Первое"), rename("Второе")])
      attach_telemetry()

      assert {:ok, {:events, 2}} =
               head(
                 id,
                 :current,
                 fn state ->
                   assert state.name == Account.Name.new!("Второе")
                   {:ok, {:events, Version.value(state.version)}}
                 end,
                 rows: rows(events)
               )

      assert_received {:telemetry, [:core, :es, :aggregate, :load], %{streams: 1, events: 2},
                       %{op: :get_decision, result: :ok}}
    end

    test "пустой поток при %Version{} — решение на незаведённом агрегате" do
      id = Account.ID.new()
      attach_telemetry()

      assert {:error, %Core.Error{code: :version_mismatch} = error} =
               head(
                 id,
                 Version.new!(1),
                 fn state ->
                   assert %Account{id: ^id, version: nil} = state
                   {:ok, :accepted}
                 end,
                 rows: []
               )

      assert error.detail == %{aggregate_id: dump(id), expected: 1, actual: nil, source: :expected}

      assert_received {:telemetry, [:core, :es, :aggregate, :load], %{streams: 1, events: 0},
                       %{op: :get_decision, result: :ok}}
    end

    test "пустой поток при %Version{} — отказ решения отдаётся как есть" do
      id = Account.ID.new()

      assert {:error, :rejected} =
               head(id, Version.new!(1), fn _state -> {:error, :rejected} end, rows: [])
    end

    test "непустой поток мимо версии — решение не зовётся" do
      id = Account.ID.new()
      events = events!(id, [open(), freeze()])
      parent = self()

      assert {:error, %Core.Error{code: :version_mismatch} = error} =
               head(
                 id,
                 Version.new!(3),
                 fn state ->
                   send(parent, :decided)
                   {:ok, state}
                 end,
                 rows: rows(events)
               )

      refute_received :decided
      assert error.detail == %{aggregate_id: dump(id), expected: 3, actual: 2, source: :expected}
    end
  end

  describe "хвост" do
    test "дочитка после версии состояния" do
      id = Account.ID.new()
      events = events!(id, [open(), rename("Второе"), freeze()])
      {_events, opened} = execute!(%Account{id: id}, open())
      attach_telemetry()

      assert {:ok, %Account{version: version, name: name, status: :frozen}} =
               tail(opened, :current, rows: rows(events))

      assert version == Version.new!(3)
      assert name == Account.Name.new!("Второе")

      assert_received {:telemetry, [:core, :es, :aggregate, :load], %{streams: 1, events: 2},
                       %{op: :refresh, result: :ok}}
    end

    test "версия состояния мимо головы — :version_mismatch" do
      id = Account.ID.new()
      events = events!(id, [open(), freeze()])
      {_events, opened} = execute!(%Account{id: id}, open())

      assert {:error, %Core.Error{code: :version_mismatch} = error} =
               tail(opened, Version.new!(1), rows: rows(events))

      assert error.detail == %{aggregate_id: dump(id), expected: 1, actual: 2, source: :expected}
    end
  end

  describe "снапшоты" do
    test "пишутся по политике операции и возможности источника строк" do
      id = Account.ID.new()
      events = events!(id, [open(), freeze()])
      {_events, opened} = execute!(%Account{id: id}, open())
      attach_telemetry()

      assert {:ok, %Account{version: version}} = head(id, :current, &{:ok, &1}, rows: rows(events))
      assert version == Version.new!(2)

      assert {:ok, %Account{version: version}} = tail(opened, :current, rows: rows(events))
      assert version == Version.new!(2)

      refute_received {:telemetry, [:core, :es, :snapshot, :write], _measurements, _metadata}
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

  defp head(id, version, fun, opts), do: Decision.head(cfg(), id, version, fun, opts)
  defp tail(state, version, opts), do: Decision.tail(cfg(), state, version, opts)

  defp cfg, do: %{LoadRepo.cfg() | source: Rows, snapshot: %{LoadRepo.cfg().snapshot | sealed: false}}

  defp events!(id, commands) do
    {events, _state} =
      Enum.reduce(commands, {[], %Account{id: id}}, fn command, {events, state} ->
        {new_events, state} = execute!(state, command)
        {events ++ new_events, state}
      end)

    events
  end

  defp rows(events) do
    type = Account.Event.Codec.__es_type__()

    entries =
      Enum.map(events, fn event ->
        fields = Core.Es.Event.Codec.to_fields(dump(event))
        {type, fields.aggregate_id, fields.aggregate_version, fields.type, fields.payload}
      end)

    Rows.rows(entries)
  end
end
