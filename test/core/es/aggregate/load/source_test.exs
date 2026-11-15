defmodule Core.Es.Aggregate.Load.SourceTest do
  use Core.DataCase, async: true

  import Core.EsAggregateRepoContract,
    only: [close: 0, dump: 1, execute!: 2, freeze: 0, open: 0, open: 1, rename: 1]

  alias Core.Es.Aggregate.Load.Plan
  alias Core.Es.Aggregate.Repo.Pg
  alias Core.Es.Aggregate.Repo.Pg.Snapshot
  alias Core.Es.Store.Rows
  alias Core.Es.Store.Schema
  alias Core.EsFixture.Account
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

  setup do
    cfg = cfg()
    id = Account.ID.new()
    other = Account.ID.new()
    {events, _state} = events!(id, [open(), rename("Второе"), freeze(), close()])
    {other_events, _state} = events!(other, [open("Другой"), rename("Третий")])
    snapshots = [{id, 3, Account.fold(%Account{id: id}, Enum.take(events, 3))}]
    rows = rows(events ++ other_events)

    %{cfg: cfg, id: id, other: other, rows: rows, snapshots: snapshots}
    |> insert_rows!()
    |> insert_snapshots!()
  end

  describe "контракт источника строк" do
    test "фикстура держит одну строку снапшота на поток", %{snapshots: snapshots} do
      counts =
        snapshots
        |> Enum.map(&elem(&1, 0))
        |> Enum.frequencies()
        |> Map.values()

      assert Enum.all?(counts, &(&1 == 1))
    end

    test "SQL и тестовый адаптер дают одинаковые тройки на границах снапшота", context do
      %{cfg: cfg, id: id, other: other, rows: rows, snapshots: snapshots} = context

      cases = [
        {:hit, id, nil, nil, false, {3, [4]}},
        {:below_address, id, Version.new!(3), nil, false, {nil, [4]}},
        {:above_ceiling, id, nil, 2, false, {nil, [1, 2]}},
        {:absent, other, nil, nil, false, {nil, [1, 2]}},
        {:rejected, id, nil, nil, true, {nil, [1, 2, 3, 4]}}
      ]

      for {name, stream_id, version, upper, refold?, expected} <- cases do
        plan = plan(cfg, stream_id, version, upper)
        plan = if refold?, do: Plan.refold(plan, [dump(stream_id)]), else: plan

        sql = Pg.fetch(cfg, plan, [])
        test = Rows.fetch(cfg, plan, rows: rows, snapshots: snapshots)

        assert normalize(sql) == normalize(test), "случай #{name}: адаптеры разошлись"
        assert triple(sql) == expected, "случай #{name}: SQL вышел за границы"
        assert triple(test) == expected, "случай #{name}: тестовый источник вышел за границы"
      end
    end
  end

  defp cfg do
    cfg = LoadRepo.cfg()

    # Контракт — границы выбора снапшота, а не шифрование: строка фикстуры лежит в той же
    # нешифрованной форме, что отдаёт тестовый источник.
    %{cfg | snapshot: %{cfg.snapshot | sealed: false}}
  end

  defp plan(cfg, id, version, upper) do
    Plan.new(cfg, true, [%{state: %Account{id: id, version: version}, version: version, upper: upper, captures: []}])
  end

  defp normalize(triples) do
    for {stream, snapshot, rows} <- triples do
      {stream, snapshot, Enum.map(rows, &Map.delete(Map.from_struct(&1), :__meta__))}
    end
  end

  defp triple([{_stream, snapshot, rows}]),
    do: {snapshot && elem(snapshot, 0), Enum.map(rows, & &1.aggregate_version)}

  defp events!(id, commands) do
    Enum.reduce(commands, {[], %Account{id: id}}, fn command, {events, state} ->
      {new_events, state} = execute!(state, command)
      {events ++ new_events, state}
    end)
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

  defp insert_rows!(context) do
    rows = Enum.map(context.rows, &Map.delete(Map.from_struct(&1), :__meta__))
    {_count, nil} = TestRepo.insert_all(Schema, rows)
    context
  end

  defp insert_snapshots!(%{cfg: cfg} = context) do
    marker = Snapshot.marker(cfg)

    rows =
      for {id, version, state} <- context.snapshots do
        %{
          aggregate_type: cfg.type,
          aggregate_id: cfg.codec.dump(id),
          aggregate_version: version,
          marker: marker,
          state: :erlang.term_to_binary(state)
        }
      end

    {_count, nil} = TestRepo.insert_all(Snapshot.Schema, rows)
    context
  end
end
