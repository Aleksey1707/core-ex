defmodule Core.Es.Aggregate.LoadTest do
  use ExUnit.Case, async: true

  import Core.EsAggregateRepoContract

  alias Core.Es.Aggregate.Load
  alias Core.Es.Aggregate.Load.Request
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

  describe "нарезка версий" do
    test "верхняя граница — события выше не читаются" do
      id = Account.ID.new()
      events = events!(id, [open("Первое"), rename("Второе"), freeze()])
      attach_telemetry()

      assert {:ok, %Account{version: version, name: name, status: :open}} =
               Load.at(no_snapshot_cfg(), at_request(id, Version.new!(2), rows(events)))

      assert version == Version.new!(2)
      assert name == Account.Name.new!("Второе")

      assert_received {:telemetry, [:core, :es, :aggregate, :fold], %{events: 2}, %{snapshot: :off}}
    end

    test "нечитаемое событие выше границы не грузится" do
      id = Account.ID.new()
      [opened] = events!(id, [open("Первое")])
      unknown = unknown_row(id, 2)

      assert {:ok, %Account{version: version}} =
               Load.at(no_snapshot_cfg(), at_request(id, Version.new!(1), rows([opened]) ++ [unknown]))

      assert version == Version.new!(1)
    end

    test "captures — потолок по наибольшей версии, состояния на версиях" do
      id = Account.ID.new()
      events = events!(id, [open(), rename("Второе"), freeze()])
      pairs = [{id, Version.new!(2)}, {id, Version.new!(3)}]
      attach_telemetry()

      assert {:ok,
              [
                %Account{version: second, status: :open},
                %Account{version: third, status: :frozen}
              ]} = Load.many_at(no_snapshot_cfg(), many_request(pairs, rows(events) ++ [unknown_row(id, 4)]))

      assert second == Version.new!(2)
      assert third == Version.new!(3)

      assert_received {:telemetry, [:core, :es, :aggregate, :fold], %{events: 3}, %{snapshot: :off}}
    end

    test "many_at — элемент не пара {%ID{}, %Version{}} — FunctionClauseError" do
      id = Account.ID.new()

      assert_raise FunctionClauseError, fn ->
        Load.many_at(no_snapshot_cfg(), many_request([{id, :current}], []))
      end
    end
  end

  describe "снапшоты" do
    test "снапшот не выше границы — начало свёртки" do
      id = Account.ID.new()
      events = events!(id, [open(), rename("Второе"), freeze()])
      snapshots = [{id, 2, Account.fold(%Account{id: id}, Enum.take(events, 2))}]
      attach_telemetry()

      assert {:ok, %Account{version: version, name: name, status: :frozen}} =
               Load.at(cfg(), at_request(id, Version.new!(3), rows(events), snapshots))

      assert version == Version.new!(3)
      assert name == Account.Name.new!("Второе")

      assert_received {:telemetry, [:core, :es, :aggregate, :fold], %{events: 1}, %{snapshot: :hit}}

      assert_received {:telemetry, [:core, :es, :aggregate, :load],
                       %{streams: 1, events: 1, snapshot_hit: 1, snapshot_miss: 0, snapshot_rejected: 0},
                       %{op: :get_at, result: :ok}}
    end

    test "снапшот новее границы — поток с начала" do
      id = Account.ID.new()
      events = events!(id, [open(), rename("Второе"), freeze()])
      snapshots = [{id, 3, Account.fold(%Account{id: id}, events)}]
      attach_telemetry()

      assert {:ok, %Account{version: version, name: name, status: :open}} =
               Load.at(cfg(), at_request(id, Version.new!(2), rows(events), snapshots))

      assert version == Version.new!(2)
      assert name == Account.Name.new!("Второе")

      assert_received {:telemetry, [:core, :es, :aggregate, :fold], %{events: 2}, %{snapshot: :miss}}
    end

    test "captures — снапшот выше наименьшей версии не используется" do
      id = Account.ID.new()
      events = events!(id, [open(), rename("Второе"), freeze()])
      pairs = [{id, Version.new!(2)}, {id, Version.new!(3)}]
      snapshots = [{id, 3, Account.fold(%Account{id: id}, events)}]
      attach_telemetry()

      assert {:ok, [%Account{version: second}, %Account{version: third}]} =
               Load.many_at(cfg(), many_request(pairs, rows(events), snapshots))

      assert second == Version.new!(2)
      assert third == Version.new!(3)

      assert_received {:telemetry, [:core, :es, :aggregate, :fold], %{events: 3}, %{snapshot: :miss}}
    end

    test "captures — снапшот на наименьшей версии используется" do
      id = Account.ID.new()
      events = events!(id, [open(), rename("Второе"), freeze(), close()])
      pairs = [{id, Version.new!(3)}, {id, Version.new!(4)}]
      snapshots = [{id, 3, Account.fold(%Account{id: id}, Enum.take(events, 3))}]
      attach_telemetry()

      assert {:ok, [%Account{version: third, status: :frozen}, %Account{version: fourth, status: :closed}]} =
               Load.many_at(cfg(), many_request(pairs, rows(events), snapshots))

      assert third == Version.new!(3)
      assert fourth == Version.new!(4)

      assert_received {:telemetry, [:core, :es, :aggregate, :fold], %{events: 1}, %{snapshot: :hit}}
    end
  end

  describe "пустой поток и адрес" do
    test "пустой поток — начальное состояние" do
      id = Account.ID.new()
      attach_telemetry()

      assert {:ok, [%Account{id: ^id, version: nil}]} =
               Load.head(no_snapshot_cfg(), head_request(id, []))

      assert_received {:telemetry, [:core, :es, :aggregate, :load], %{streams: 1, events: 0}, %{op: :get, result: :ok}}

      assert_received {:telemetry, [:core, :es, :aggregate, :fold], %{events: 0}, %{snapshot: :off}}
    end

    test "адрес за головой потока — detail source: :address" do
      id = Account.ID.new()
      events = events!(id, [open(), rename("Второе")])
      version = Version.new!(3)

      request = Request.get_at(LoadRepo.cfg(), id, version, [], Rows.source(rows(events)))
      request = %{request | write_snapshots?: false}

      assert {:error, %Core.Error{code: :version_mismatch} = error} =
               Load.at(no_snapshot_cfg(), request)

      assert error.detail == %{aggregate_id: dump(id), expected: 3, actual: 2, source: :address}
    end

    test "many_at — расхождения одной ошибкой в порядке пар" do
      [first, second, empty] = [Account.ID.new(), Account.ID.new(), Account.ID.new()]
      first_rows = rows(events!(first, [open("Первый")]))
      second_rows = rows(events!(second, [open("Второй"), rename("Третий")]))

      pairs = [
        {first, Version.new!(2)},
        {empty, Version.new!(1)},
        {second, Version.new!(3)},
        {first, Version.new!(2)}
      ]

      request = Request.get_many_at(LoadRepo.cfg(), pairs, [], Rows.source(first_rows ++ second_rows))
      request = %{request | write_snapshots?: false}

      assert {:error, %Core.Error{code: :version_mismatch} = error} =
               Load.many_at(no_snapshot_cfg(), request)

      assert error.detail == [
               %{aggregate_id: dump(first), expected: 2, actual: 1, source: :address},
               %{aggregate_id: dump(empty), expected: 1, actual: nil, source: :address},
               %{aggregate_id: dump(second), expected: 3, actual: 2, source: :address},
               %{aggregate_id: dump(first), expected: 2, actual: 1, source: :address}
             ]
    end
  end

  def handle_telemetry(event, measurements, metadata, test) do
    if self() == test, do: send(test, {:telemetry, event, measurements, metadata})
  end

  defp attach_telemetry do
    handler = {__MODULE__, make_ref()}

    events = [
      Telemetry.event([:es, :aggregate, :load]),
      Telemetry.event([:es, :aggregate, :fold])
    ]

    :ok = :telemetry.attach_many(handler, events, &__MODULE__.handle_telemetry/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp cfg, do: %{LoadRepo.cfg() | snapshot: %{LoadRepo.cfg().snapshot | sealed: false}}

  defp no_snapshot_cfg, do: %{LoadRepo.cfg() | snapshot: nil}

  defp head_request(id, rows) do
    request = Request.get(LoadRepo.cfg(), id, :current, [], Rows.source(rows))
    %{request | write_snapshots?: false}
  end

  defp at_request(id, version, rows, snapshots \\ []) do
    request = Request.get_at(LoadRepo.cfg(), id, version, [], Rows.source(rows, snapshots))
    %{request | write_snapshots?: false}
  end

  defp many_request(pairs, rows, snapshots \\ []) do
    request = Request.get_many_at(LoadRepo.cfg(), pairs, [], Rows.source(rows, snapshots))
    %{request | write_snapshots?: false}
  end

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

  defp unknown_row(id, version) do
    [row] = Rows.rows([{Account.Event.Codec.__es_type__(), dump(id), version, "account.unknown", %{}}])
    row
  end
end
