defmodule Core.Codec.PluginFieldsTest do
  use ExUnit.Case, async: true

  alias Core.Error
  alias Core.Prim
  alias Core.PrimFixture
  alias Core.Version

  defmodule Name do
    use Prim.String, name: "Имя", min_len: 1, max_len: 50
  end

  defmodule ID do
    use Prim.UUID, name: "ID", version: 4
  end

  defmodule OwnerID do
    use Prim.Compose, name: "Владелец", of: ID
  end

  defmodule Item do
    defstruct [:id, :name, :owner_id, :secret, :version, :note, events: []]
  end

  defmodule Tag do
    defstruct [:name]
  end

  defmodule Status do
    use Core.Enum,
      name: "Статус",
      values: ~w(new done)a
  end

  defmodule Card do
    defstruct [:status, :prev_status, :tag, :parent, :tags, :statuses, :grid, :count, :meta, :label, :rank, :flag]
  end

  defmodule Plugin do
    use Core.Codec.Plugin,
      types: [Item, Tag, Card],
      fields: [
        {Item,
         id: [prim: ID],
         name: [prim: Name, wire: "title"],
         owner_id: [prim: OwnerID],
         secret: [prim: PrimFixture.Password],
         version: [prim: Version],
         note: [prim: Name, optional: true]},
        {Tag, name: [prim: Name]},
        {Card,
         status: [enum: Status],
         prev_status: [enum: Status, optional: true],
         tag: [entity: Tag],
         parent: [entity: Tag, optional: true],
         tags: [list: [entity: Tag]],
         statuses: [list: [enum: Status], optional: true],
         grid: [list: [list: [prim: Name]]],
         count: [type: :non_neg_integer],
         meta: [type: :map, optional: true],
         label: [prim: Name, default: "без имени"],
         rank: [enum: Status, default: "new"],
         flag: [type: :boolean, default: true]}
      ]
  end

  defmodule Facade do
    use Core.Codec.Facade,
      prim: Core.CodecFixture.Prim.Internal,
      plugins: [Plugin]
  end

  setup do
    item = %Item{
      id: ID.new!("6f1f8b8e-6b5a-4c47-9d5e-0b7c1d0e8f11"),
      name: Name.new!("Стол"),
      owner_id: OwnerID.new!("1d2c3b4a-5e6f-4a7b-8c9d-0e1f2a3b4c5d"),
      secret: PrimFixture.Password.new!("secret-password"),
      version: Version.new!(3),
      note: nil
    }

    %{item: item}
  end

  test "dump даёт wire-map по полям, ключ — wire: или имя поля", %{item: item} do
    assert Facade.dump(item) == %{
             "id" => "6f1f8b8e-6b5a-4c47-9d5e-0b7c1d0e8f11",
             "title" => "Стол",
             "owner_id" => "1d2c3b4a-5e6f-4a7b-8c9d-0e1f2a3b4c5d",
             "secret" => "secret-password",
             "version" => 3,
             "note" => nil
           }
  end

  test "round-trip через фасад", %{item: item} do
    assert Facade.load(Item, Facade.dump(item)) == {:ok, item}

    item = %{item | note: Name.new!("у окна")}
    assert Facade.load(Item, Facade.dump(item)) == {:ok, item}
    assert Facade.load(Tag, Facade.dump(%Tag{name: Name.new!("x")})) == {:ok, %Tag{name: Name.new!("x")}}
  end

  test "optional: отсутствующий ключ — nil", %{item: item} do
    wire = Map.delete(Facade.dump(item), "note")

    assert {:ok, %Item{note: nil}} = Facade.load(Item, wire)
  end

  test "чтение по wire: и атомарным ключам, лишние ключи игнорируются", %{item: item} do
    wire =
      item
      |> Facade.dump()
      |> Map.new(fn {key, value} -> {String.to_atom(key), value} end)
      |> Map.put(:unknown, "x")

    assert Facade.load(Item, wire) == {:ok, item}
  end

  test "первая ошибка поля — итог", %{item: item} do
    wire = %{Facade.dump(item) | "id" => "not-uuid", "title" => ""}

    assert {:error, %Error{module: ID}} = Facade.load(Item, wire)
  end

  test "обязательное поле без ключа — ошибка его Prim", %{item: item} do
    wire = Map.delete(Facade.dump(item), "title")

    assert {:error, %Error{module: Name}} = Facade.load(Item, wire)
  end

  test "значение не того Prim — FunctionClauseError", %{item: item} do
    assert_raise FunctionClauseError, fn -> Facade.dump(%{item | name: "Стол"}) end
    assert_raise FunctionClauseError, fn -> Facade.dump(%{item | note: "у окна"}) end
  end

  describe "виды поля" do
    setup do
      card = %Card{
        status: :done,
        prev_status: nil,
        tag: %Tag{name: Name.new!("a")},
        parent: %Tag{name: Name.new!("p")},
        tags: [%Tag{name: Name.new!("b")}, %Tag{name: Name.new!("c")}],
        statuses: [:new, :done],
        grid: [[Name.new!("x")], []],
        count: 2,
        meta: %{"k" => 1},
        label: Name.new!("метка"),
        rank: :done,
        flag: false
      }

      %{card: card}
    end

    test "dump: enum и type — как есть, entity и list — через фасад", %{card: card} do
      assert Facade.dump(card) == %{
               "status" => :done,
               "prev_status" => nil,
               "tag" => %{"name" => "a"},
               "parent" => %{"name" => "p"},
               "tags" => [%{"name" => "b"}, %{"name" => "c"}],
               "statuses" => [:new, :done],
               "grid" => [["x"], []],
               "count" => 2,
               "meta" => %{"k" => 1},
               "label" => "метка",
               "rank" => :done,
               "flag" => false
             }
    end

    test "round-trip через фасад, enum из строки — cast", %{card: card} do
      assert Facade.load(Card, Facade.dump(card)) == {:ok, card}

      wire = %{Facade.dump(card) | "status" => "done", "statuses" => ["new", "done"]}
      assert Facade.load(Card, wire) == {:ok, card}

      card = %{card | parent: nil, statuses: nil, meta: nil}
      assert Facade.load(Card, Facade.dump(card)) == {:ok, card}
    end

    test "optional: отсутствующий ключ — nil", %{card: card} do
      wire = Map.drop(Facade.dump(card), ~w(prev_status parent statuses meta))

      assert {:ok, %Card{prev_status: nil, parent: nil, statuses: nil, meta: nil}} = Facade.load(Card, wire)
    end

    test "отказ cast enum — ошибка загрузки", %{card: card} do
      assert {:error, %Error{module: Status, code: :invalid_value}} =
               Facade.load(Card, %{Facade.dump(card) | "status" => "lost"})

      assert {:error, %Error{module: Status}} = Facade.load(Card, %{Facade.dump(card) | "statuses" => ["lost"]})
    end

    test "ошибка элемента list: и entity: — итог", %{card: card} do
      assert {:error, %Error{module: Name}} = Facade.load(Card, %{Facade.dump(card) | "tags" => [%{"name" => ""}]})
      assert {:error, %Error{module: Name}} = Facade.load(Card, %{Facade.dump(card) | "grid" => [[""]]})
      assert {:error, %Error{module: Name}} = Facade.load(Card, %{Facade.dump(card) | "tag" => %{"name" => ""}})
    end

    test "list: не списком — ошибка загрузки", %{card: card} do
      assert {:error, %Error{module: Card, ns: :codec, code: :invalid_value}} =
               Facade.load(Card, Map.delete(Facade.dump(card), "tags"))

      assert {:error, %Error{module: Card, code: :invalid_value}} =
               Facade.load(Card, %{Facade.dump(card) | "grid" => ["x"]})
    end

    test "default: — при отсутствии ключа и при nil, загружается как записанное", %{card: card} do
      wire =
        card
        |> Facade.dump()
        |> Map.drop(~w(label flag))
        |> Map.put("rank", nil)

      assert {:ok, %Card{label: label, rank: :new, flag: true}} = Facade.load(Card, wire)
      assert label == Name.new!("без имени")
    end

    test "default: не подменяет записанное значение, в т.ч. false", %{card: card} do
      assert {:ok, %Card{flag: false, rank: :done}} = Facade.load(Card, Facade.dump(card))
    end

    test "значение не того вида — FunctionClauseError", %{card: card} do
      assert_raise FunctionClauseError, fn -> Facade.dump(%{card | status: "done"}) end
      assert_raise FunctionClauseError, fn -> Facade.dump(%{card | status: nil}) end
      assert_raise FunctionClauseError, fn -> Facade.dump(%{card | tag: Name.new!("a")}) end
      assert_raise FunctionClauseError, fn -> Facade.dump(%{card | tags: nil}) end
      assert_raise FunctionClauseError, fn -> Facade.dump(%{card | count: -1}) end
      assert_raise FunctionClauseError, fn -> Facade.dump(%{card | meta: []}) end
    end
  end

  describe "сборка" do
    test "поле struct без спеки и поле спеки без struct — CompileError" do
      assert_raise CompileError, ~r/поля struct без спеки \[:b\], поля спеки без struct \[:c\]/, fn ->
        compile_plugin(:StructMismatch, a: [prim: Name], c: [prim: Name])
      end
    end

    test "ключ fields: вне types: — CompileError" do
      assert_raise CompileError, ~r/типы вне types:/, fn ->
        Code.eval_quoted(
          quote do
            defmodule Core.Codec.PluginFieldsTest.Foreign do
              use Core.Codec.Plugin,
                types: [Core.Codec.PluginFieldsTest.Tag],
                fields: [{Core.Codec.PluginFieldsTest.Item, id: [prim: Core.Codec.PluginFieldsTest.ID]}]
            end
          end
        )
      end
    end

    test "тип объявлен дважды — CompileError" do
      assert_raise CompileError, ~r/типы объявлены дважды/, fn ->
        Code.eval_quoted(
          quote do
            defmodule Core.Codec.PluginFieldsTest.Twice do
              use Core.Codec.Plugin,
                types: [Core.Codec.PluginFieldsTest.Tag],
                fields: [
                  {Core.Codec.PluginFieldsTest.Tag, name: [prim: Core.Codec.PluginFieldsTest.Name]},
                  {Core.Codec.PluginFieldsTest.Tag, name: [prim: Core.Codec.PluginFieldsTest.Name]}
                ]
            end
          end
        )
      end
    end

    test "не Prim в prim: — CompileError с именем плагина, типа и поля" do
      message = ~r/Codec.Plugin .*NotPrim: fields:, тип .*NotPrim.T, поле b: .*Tag не Prim/

      assert_raise CompileError, message, fn ->
        compile_plugin(:NotPrim, a: [prim: Name], b: [prim: Core.Codec.PluginFieldsTest.Tag])
      end
    end

    test "повтор поля и повтор wire-ключа — CompileError" do
      assert_raise CompileError, ~r/поля повторяются: \[:a\]/, fn ->
        compile_plugin(:DupField, a: [prim: Name], a: [prim: Name, wire: "b"])
      end

      assert_raise CompileError, ~r/wire-ключи повторяются: \["b"\]/, fn ->
        compile_plugin(:DupWire, a: [prim: Name, wire: "b"], b: [prim: Name])
      end
    end

    test "неизвестный ключ спеки — CompileError" do
      assert_raise CompileError, ~r/поле a: неизвестные ключи \[:default_value\]/, fn ->
        compile_plugin(:UnknownKey, a: [prim: Name, default_value: 1], b: [prim: Name])
      end
    end

    test "не enum в enum: — CompileError" do
      assert_raise CompileError, ~r/поле a: .*Name не Core.Enum/, fn ->
        compile_plugin(:NotEnum, a: [enum: Name], b: [prim: Name])
      end
    end

    test "не struct в entity: — CompileError" do
      assert_raise CompileError, ~r/поле a: .*Status не struct/, fn ->
        compile_plugin(:NotEntity, a: [entity: Core.Codec.PluginFieldsTest.Status], b: [prim: Name])
      end
    end

    test "неизвестный type: — CompileError" do
      assert_raise CompileError, ~r/поле a: неизвестный type: :atom/, fn ->
        compile_plugin(:UnknownType, a: [type: :atom], b: [prim: Name])
      end
    end

    test "два вида в поле — CompileError" do
      assert_raise CompileError, ~r/поле a: нужен ровно один из prim:\/enum:\/entity:\/list:\/type:/, fn ->
        compile_plugin(:TwoKinds, a: [prim: Name, type: :string], b: [prim: Name])
      end
    end

    test "optional: внутри list: — CompileError" do
      assert_raise CompileError, ~r/поле a: optional: задаётся у самого поля, не в list:/, fn ->
        compile_plugin(:ListOptional, a: [list: [prim: Name, optional: true]], b: [prim: Name])
      end
    end

    test "default: с optional: true — CompileError" do
      assert_raise CompileError, ~r/поле a: default: и optional: true/, fn ->
        compile_plugin(:DefaultOptional, a: [prim: Name, optional: true, default: "x"], b: [prim: Name])
      end
    end

    test "default: при loadable: false — CompileError" do
      assert_raise CompileError, ~r/поле a: default: при loadable: false/, fn ->
        compile_plugin(:DefaultDumpOnly, [a: [prim: Name, default: "x"], b: [prim: Name]], loadable: false)
      end
    end
  end

  # ---

  defp compile_plugin(name, spec, opts \\ []) do
    plugin = Module.concat(__MODULE__, name)
    type = Module.concat(plugin, T)
    spec = Macro.escape(spec)

    Code.eval_quoted(
      quote do
        defmodule unquote(plugin) do
          defmodule unquote(type) do
            defstruct [:a, :b]
          end

          use Core.Codec.Plugin,
            types: [unquote(type)],
            loadable: unquote(Keyword.get(opts, :loadable, true)),
            fields: [{unquote(type), unquote(spec)}]
        end
      end
    )
  end
end
