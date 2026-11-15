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

  describe "заявка read-model операций" do
    test "несёт только поля операций чтения" do
      fields = Request.__struct__() |> Map.from_struct() |> Map.keys() |> Enum.sort()

      assert fields == [:op, :opts, :pairs, :source, :streams, :version]
    end
  end

  describe "нарезка версий" do
    test "верхняя граница — события выше не читаются" do
      id = Account.ID.new()
      events = events!(id, [open("Первое"), rename("Второе"), freeze()])
      attach_telemetry()

      assert {:ok, %Account{version: version, name: name, status: :open}} =
               Load.run(no_snapshot_cfg(), at_request(id, Version.new!(2), rows(events)))

      assert version == Version.new!(2)
      assert name == Account.Name.new!("Второе")

      assert_received {:telemetry, [:core, :es, :aggregate, :fold], %{events: 2}, %{snapshot: :off}}
    end

    test "нечитаемое событие выше границы не грузится" do
      id = Account.ID.new()
      [opened] = events!(id, [open("Первое")])
      unknown = unknown_row(id, 2)

      assert {:ok, %Account{version: version}} =
               Load.run(no_snapshot_cfg(), at_request(id, Version.new!(1), rows([opened]) ++ [unknown]))

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
              ]} = Load.run(no_snapshot_cfg(), many_request(pairs, rows(events) ++ [unknown_row(id, 4)]))

      assert second == Version.new!(2)
      assert third == Version.new!(3)

      assert_received {:telemetry, [:core, :es, :aggregate, :fold], %{events: 3}, %{snapshot: :off}}
    end

    test "many_at — элемент не пара {%ID{}, %Version{}} — FunctionClauseError" do
      id = Account.ID.new()

      assert_raise FunctionClauseError, fn ->
        Load.run(no_snapshot_cfg(), many_request([{id, :current}], []))
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
               Load.run(cfg(), at_request(id, Version.new!(3), rows(events), snapshots))

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
               Load.run(cfg(), at_request(id, Version.new!(2), rows(events), snapshots))

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
               Load.run(cfg(), many_request(pairs, rows(events), snapshots))

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
               Load.run(cfg(), many_request(pairs, rows(events), snapshots))

      assert third == Version.new!(3)
      assert fourth == Version.new!(4)

      assert_received {:telemetry, [:core, :es, :aggregate, :fold], %{events: 1}, %{snapshot: :hit}}
    end

    test "отвергнутый снапшот — повторное чтение без снапшота" do
      id = Account.ID.new()
      events = events!(id, [open(), rename("Второе"), freeze()])
      attach_telemetry()

      assert {:ok, %Account{version: version, name: name, status: :frozen}} =
               Load.run(cfg(), at_request(id, Version.new!(3), rows(events), [{id, 2, :corrupt}]))

      assert version == Version.new!(3)
      assert name == Account.Name.new!("Второе")

      assert_received {:telemetry, [:core, :es, :aggregate, :fold], %{events: 3}, %{snapshot: :rejected}}
    end

    test "маркер снапшота считается один раз за чтение" do
      id = Account.ID.new()
      events = events!(id, [open()])
      marker = {Core.Es.Aggregate.Repo.Pg.Snapshot, :marker, 1}
      parent = self()
      tracer = spawn(fn -> forward_marker(parent) end)
      on_exit(fn -> Process.exit(tracer, :kill) end)

      :erlang.trace(self(), true, [:call, {:tracer, tracer}])
      :erlang.trace_pattern(marker, true, [])
      on_exit(fn -> :erlang.trace_pattern(marker, false, []) end)

      assert {:ok, _state} = Load.run(cfg(), head_request(id, rows(events)))

      :erlang.trace(self(), false, [:call])
      :erlang.trace_pattern(marker, false, [])

      assert_receive :marker, 100
      refute_receive :marker, 50
    end

    test "расшифрованный снапшот приходит вместе со своим потоком" do
      [first, second] = [Account.ID.new(), Account.ID.new()]
      first_events = events!(first, [open("Первый"), rename("Первый два")])
      second_events = events!(second, [open("Второй"), rename("Второй два")])

      snapshots = [
        {first, 1, Account.fold(%Account{id: first}, Enum.take(first_events, 1))},
        {second, 1, Account.fold(%Account{id: second}, Enum.take(second_events, 1))}
      ]

      pairs = [{first, Version.new!(2)}, {second, Version.new!(2)}]
      rows = rows(first_events ++ second_events)
      request = Request.get_many_at(LoadRepo.cfg(), pairs, [rows: rows, snapshots: snapshots, order: :reverse], Rows)
      attach_telemetry()

      assert {:ok, [first_state, second_state]} = Load.run(cfg(), request)
      assert first_state.name == Account.Name.new!("Первый два")
      assert second_state.name == Account.Name.new!("Второй два")

      assert_received {:telemetry, [:core, :es, :aggregate, :fold], %{events: 1}, %{snapshot: :hit}}
      assert_received {:telemetry, [:core, :es, :aggregate, :fold], %{events: 1}, %{snapshot: :hit}}

      assert_received {:telemetry, [:core, :es, :aggregate, :load],
                       %{streams: 2, events: 2, snapshot_hit: 2, snapshot_miss: 0, snapshot_rejected: 0},
                       %{op: :get_many_at, result: :ok}}
    end
  end

  describe "пустой поток и адрес" do
    test "пустой поток — начальное состояние" do
      id = Account.ID.new()
      attach_telemetry()

      assert {:ok, [%Account{id: ^id, version: nil}]} =
               Load.run(no_snapshot_cfg(), head_request(id, []))

      assert_received {:telemetry, [:core, :es, :aggregate, :load], %{streams: 1, events: 0}, %{op: :get, result: :ok}}

      assert_received {:telemetry, [:core, :es, :aggregate, :fold], %{events: 0}, %{snapshot: :off}}
    end

    test "адрес за головой потока — detail source: :address" do
      id = Account.ID.new()
      events = events!(id, [open(), rename("Второе")])
      version = Version.new!(3)

      request = Request.get_at(LoadRepo.cfg(), id, version, [rows: rows(events)], Rows)

      assert {:error, %Core.Error{code: :version_mismatch} = error} =
               Load.run(no_snapshot_cfg(), request)

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

      request = Request.get_many_at(LoadRepo.cfg(), pairs, [rows: first_rows ++ second_rows], Rows)

      assert {:error, %Core.Error{code: :version_mismatch} = error} =
               Load.run(no_snapshot_cfg(), request)

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

  defp forward_marker(test) do
    receive do
      {:trace, _pid, :call, {Core.Es.Aggregate.Repo.Pg.Snapshot, :marker, [_]}} -> send(test, :marker)
      _other -> :ok
    end

    forward_marker(test)
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

  defp head_request(id, rows), do: Request.get(LoadRepo.cfg(), id, :current, [rows: rows], Rows)

  defp at_request(id, version, rows, snapshots \\ []),
    do: Request.get_at(LoadRepo.cfg(), id, version, [rows: rows, snapshots: snapshots], Rows)

  defp many_request(pairs, rows, snapshots \\ []),
    do: Request.get_many_at(LoadRepo.cfg(), pairs, [rows: rows, snapshots: snapshots], Rows)

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
