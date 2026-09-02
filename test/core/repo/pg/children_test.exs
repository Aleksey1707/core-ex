defmodule Core.Repo.Pg.ChildrenTest do
  use ExUnit.Case, async: true

  alias Core.Repo

  defmodule Parent do
    @moduledoc false

    defstruct id: "p1", links: [], data: [], triples: []
  end

  defmodule Link do
    @moduledoc false

    use Ecto.Schema

    @primary_key false

    schema "children_links" do
      field :parent_id, :string, primary_key: true
      field :child_id, :string, primary_key: true
    end

    def to_models(%Parent{} = parent), do: parent.links
  end

  defmodule Data do
    @moduledoc false

    use Ecto.Schema

    @primary_key false

    schema "children_data" do
      field :parent_id, :string, primary_key: true
      field :code, :string, primary_key: true
      field :name, :string
      field :position, :integer
    end

    def to_models(%Parent{} = parent), do: parent.data
  end

  defmodule Triple do
    @moduledoc false

    use Ecto.Schema

    @primary_key false

    schema "children_triples" do
      field :parent_id, :string, primary_key: true
      field :code, :string, primary_key: true
      field :item_id, :string, primary_key: true
      field :status, :string
    end

    def to_models(%Parent{} = parent), do: parent.triples
  end

  defmodule Dao do
    @moduledoc false

    def insert_all(schema, rows, opts) do
      send(self(), {:insert_all, schema, rows, opts})
      {length(rows), nil}
    end

    def delete_all(query, opts) do
      send(self(), {:delete_all, query, opts})
      {0, nil}
    end
  end

  @pg %{dao: Dao, to_id: &Function.identity/1, module: __MODULE__, errors: __MODULE__}

  describe "plan/3" do
    test "пустой набор с обеих сторон" do
      assert Repo.Pg.Children.plan(data_spec(), [], []) ==
               %{insert: [], update: [], delete: []}
    end

    test "новая строка попадает в insert" do
      row = data_row("a")

      assert Repo.Pg.Children.plan(data_spec(), [], [row]) ==
               %{insert: [row], update: [], delete: []}
    end

    test "исчезнувшая строка попадает в delete ключом" do
      row = data_row("a")

      assert Repo.Pg.Children.plan(data_spec(), [row], []) ==
               %{insert: [], update: [], delete: [%{code: "a"}]}
    end

    test "изменение не-ключевого поля попадает в update" do
      was = data_row("a")
      now = %{was | name: "изменено"}

      assert Repo.Pg.Children.plan(data_spec(), [was], [now]) ==
               %{insert: [], update: [now], delete: []}
    end

    test "неизменённая строка не попадает никуда" do
      row = data_row("a")

      assert Repo.Pg.Children.plan(data_spec(), [row], [row]) ==
               %{insert: [], update: [], delete: []}
    end

    test "тот же набор в другом порядке даёт пустой план" do
      rows = [data_row("a"), data_row("b")]

      assert Repo.Pg.Children.plan(data_spec(), rows, Enum.reverse(rows)) ==
               %{insert: [], update: [], delete: []}
    end

    test "смена ключа — это insert плюс delete" do
      was = data_row("a")
      now = data_row("b")

      assert Repo.Pg.Children.plan(data_spec(), [was], [now]) ==
               %{insert: [now], update: [], delete: [%{code: "a"}]}
    end

    test "дубль ключа в наборе — ArgumentError с именем схемы" do
      rows = [data_row("a"), %{data_row("a") | name: "другое"}]

      assert_raise ArgumentError, ~r/ChildrenTest\.Data\.to_models\/1/, fn ->
        Repo.Pg.Children.plan(data_spec(), [], rows)
      end
    end
  end

  describe "sync/5" do
    test "пустой план не идёт в БД ни одним запросом" do
      parent = %Parent{data: [data_row("a")]}

      assert :ok = Repo.Pg.Children.sync(@pg, [data_spec()], parent, parent, [])

      refute_received {:insert_all, _, _, _}
      refute_received {:delete_all, _, _}
    end

    test "с эталоном: один delete_all и один insert_all с upsert" do
      baseline = %Parent{data: [data_row("a"), data_row("b")]}
      parent = %Parent{data: [%{data_row("a") | name: "изменено"}, data_row("c")]}

      assert :ok = Repo.Pg.Children.sync(@pg, [data_spec()], parent, baseline, [])

      assert_received {:delete_all, delete_query, []}
      assert {sql, params} = to_sql(delete_query)
      assert sql =~ ~s("children_data")
      assert params == ["p1", ["b"]]

      assert_received {:insert_all, Data, rows, opts}
      assert Enum.map(rows, & &1.code) == ["c", "a"]
      assert opts[:on_conflict] == {:replace, ~w(name position)a}
      assert opts[:conflict_target] == ~w(parent_id code)a
    end

    test "link-таблица без прочих колонок — on_conflict: :nothing" do
      parent = %Parent{links: [link_row("c1")]}

      assert :ok = Repo.Pg.Children.sync(@pg, [link_spec()], parent, %Parent{}, [])

      assert_received {:insert_all, Link, _rows, opts}
      assert opts[:on_conflict] == :nothing
      assert opts[:conflict_target] == ~w(parent_id child_id)a
    end

    test "без эталона: delete_all исключает текущий набор, затем upsert" do
      parent = %Parent{data: [data_row("a")]}

      assert :ok = Repo.Pg.Children.sync(@pg, [data_spec()], parent, nil, [])

      assert_received {:delete_all, delete_query, []}
      assert {sql, params} = to_sql(delete_query)
      assert sql =~ "NOT ("
      assert params == ["p1", ["a"]]

      assert_received {:insert_all, Data, _rows, opts}
      assert opts[:on_conflict] == {:replace, ~w(name position)a}
    end

    test "без эталона и с пустым набором: delete_all только по fk" do
      assert :ok = Repo.Pg.Children.sync(@pg, [data_spec()], %Parent{}, nil, [])

      assert_received {:delete_all, delete_query, []}
      assert {sql, params} = to_sql(delete_query)
      refute sql =~ "NOT ("
      assert params == ["p1"]

      refute_received {:insert_all, _, _, _}
    end

    test "многоколоночный ключ — OR-цепочка равенств" do
      parent = %Parent{triples: [triple_row("s1", "i1"), triple_row("s2", "i2")]}

      assert :ok = Repo.Pg.Children.sync(@pg, [triple_spec()], parent, nil, [])

      assert_received {:delete_all, delete_query, []}
      assert {sql, params} = to_sql(delete_query)
      assert sql =~ " OR "
      assert params == ["p1", "s1", "i1", "s2", "i2"]
    end

    test "опции call site не перебивают upsert" do
      parent = %Parent{data: [data_row("a")]}

      assert :ok = Repo.Pg.Children.sync(@pg, [data_spec()], parent, %Parent{}, prefix: "tenant")

      assert_received {:insert_all, Data, _rows, opts}
      assert opts[:prefix] == "tenant"
      assert opts[:conflict_target] == ~w(parent_id code)a
    end
  end

  describe "insert/4" do
    test "простой insert_all без on_conflict" do
      parent = %Parent{data: [data_row("a")]}

      assert :ok = Repo.Pg.Children.insert(@pg, [data_spec()], parent, [])

      assert_received {:insert_all, Data, rows, opts}
      assert Enum.map(rows, & &1.code) == ["a"]
      assert opts == []

      refute_received {:delete_all, _, _}
    end

    test "пустой набор не идёт в БД" do
      assert :ok = Repo.Pg.Children.insert(@pg, [data_spec()], %Parent{}, [])

      refute_received {:insert_all, _, _, _}
    end

    test "набор больше чанка режется на несколько insert_all" do
      size = Repo.Pg.Children.chunk_size()
      parent = %Parent{data: Enum.map(1..(size + 1), &data_row("c#{&1}"))}

      assert :ok = Repo.Pg.Children.insert(@pg, [data_spec()], parent, [])

      assert_received {:insert_all, Data, first, _}
      assert_received {:insert_all, Data, second, _}
      assert length(first) == size
      assert length(second) == 1
    end
  end

  defp to_sql(query), do: Ecto.Adapters.SQL.to_sql(:delete_all, Core.TestRepo, query)

  defp data_spec, do: spec(Data, ~w(code)a, ~w(name position)a)
  defp link_spec, do: spec(Link, ~w(child_id)a, [])
  defp triple_spec, do: spec(Triple, ~w(code item_id)a, ~w(status)a)

  defp spec(schema, key, replace) do
    %{
      schema: schema,
      fk: :parent_id,
      key: key,
      conflict_target: [:parent_id | key],
      replace: replace,
      constraint_errors: %{}
    }
  end

  defp data_row(code),
    do: %{parent_id: "p1", code: code, name: "имя #{code}", position: 1}

  defp link_row(child_id), do: %{parent_id: "p1", child_id: child_id}

  defp triple_row(code, item_id),
    do: %{parent_id: "p1", code: code, item_id: item_id, status: "new"}
end
