defmodule Core.StructTest do
  use ExUnit.Case, async: true

  alias Core.StructFixture
  alias Core.StructFixture.Name
  alias Core.StructFixture.Wide

  describe "use Core.Struct" do
    test "defstruct — все поля, значение nil" do
      assert Map.from_struct(struct(Wide)) ==
               Map.new(~w(name note status point shape tags matrix count title attrs)a, &{&1, nil})
    end

    test "struct собирается литералом, Prim лежит в поле сам" do
      title = StructFixture.Nested.Title.new!("Отгрузка")

      assert %StructFixture.Nested{title: ^title} = %StructFixture.Nested{title: title}
    end

    test "обязательны все поля, и optional: тоже" do
      assert_raise ArgumentError,
                   ~r/\[:name, :note, :status, :point, :shape, :tags, :matrix, :count, :title, :attrs\]/,
                   fn -> Code.eval_string("%Core.StructFixture.Wide{}") end
    end
  end

  describe "@type t" do
    setup do
      {:ok, types} = Code.Typespec.fetch_types(Wide)
      %{fields: struct_type_fields(types)}
    end

    test "prim:, enum: и entity: — тип своего модуля", %{fields: fields} do
      assert fields[:name] == "Core.StructFixture.Name.t()"
      assert fields[:status] == "Core.StructFixture.Status.t()"
      assert fields[:point] == "Core.StructFixture.Point.t()"
    end

    test "union: — struct()", %{fields: fields} do
      assert fields[:shape] == "struct()"
    end

    test "list: — список типа элемента, и вложенный тоже", %{fields: fields} do
      assert fields[:tags] == "[Core.StructFixture.Name.t()]"
      assert fields[:matrix] == "[[integer()]]"
    end

    test "type: — тип примитива", %{fields: fields} do
      assert fields[:count] == "non_neg_integer()"
      assert fields[:title] == "String.t()"
    end

    test "optional: true добавляет | nil", %{fields: fields} do
      assert fields[:note] == "Core.StructFixture.Name.t() | nil"
      assert fields[:attrs] == "map() | nil"
    end

    test "Prim, вложенный выше use, — тип вложенного модуля" do
      {:ok, types} = Code.Typespec.fetch_types(StructFixture.Nested)

      assert struct_type_fields(types) == %{title: "Core.StructFixture.Nested.Title.t()"}
    end
  end

  describe "отказы декларации" do
    test "wire: — CompileError" do
      assert_raise CompileError, ~r/^Struct: fields: name: wire: у структуры по полям нет wire/, fn ->
        define(fields: [name: [prim: Name, wire: "title"]])
      end
    end

    test "subject: — CompileError" do
      assert_raise CompileError, ~r/^Struct: fields: name: subject: у структуры по полям нет кодека/, fn ->
        define(fields: [name: [prim: Name, subject: :aggregate_id]])
      end
    end

    test "default: — CompileError" do
      assert_raise CompileError, ~r/^Struct: fields: count: default: /, fn ->
        define(fields: [count: [type: :integer, default: 0]])
      end
    end

    test "prim: не Prim — CompileError" do
      assert_raise CompileError, ~r/^Struct: fields: name: Core.StructFixture.Status не Prim$/, fn ->
        define(fields: [name: [prim: StructFixture.Status]])
      end
    end

    test "enum: не Enum — CompileError" do
      assert_raise CompileError, ~r/^Struct: fields: status: Core.StructFixture.Name не Core.Enum$/, fn ->
        define(fields: [status: [enum: Name]])
      end
    end

    test "несобранный модуль — CompileError" do
      assert_raise CompileError, ~r/^Struct: fields: name: Core.StructFixture.Missing недоступен/, fn ->
        define(fields: [name: [prim: StructFixture.Missing]])
      end
    end

    test "неизвестное значение type: — CompileError" do
      assert_raise CompileError, ~r/^Struct: fields: count: неизвестный type: :float/, fn ->
        define(fields: [count: [type: :float]])
      end
    end

    test "повтор поля — CompileError" do
      assert_raise CompileError, ~r/^Struct: fields: name: поле объявлено повторно$/, fn ->
        define(fields: [name: [prim: Name], name: [prim: Name, optional: true]])
      end
    end

    test "атрибут в fields: — «ожидается литерал»" do
      assert_raise CompileError, ~r/^Struct: fields: ожидается литерал, получено @fields$/, fn ->
        Code.eval_quoted(
          quote do
            defmodule Core.StructTest.AttrFields do
              @fields [name: [prim: Core.StructFixture.Name]]
              use Core.Struct, fields: @fields
            end
          end
        )
      end
    end

    test "вызов в спеке поля — «ожидается литерал»" do
      assert_raise CompileError, ~r/^Struct: fields: ожидается литерал, получено /, fn ->
        define(quote(do: [fields: [name: [prim: Module.concat(Core.StructFixture, Name)]]]))
      end
    end

    test "опечатка в ключе — при раскрытии, с меткой" do
      assert_raise CompileError, ~r/^Struct: нет обязательных опций: \[:fields\]; неизвестные опции: \[:field\]$/, fn ->
        define(field: [name: [prim: Name]])
      end
    end
  end

  defp struct_type_fields(types) do
    {:type, {:t, {:type, _, :map, entries}, []}} = Enum.find(types, &match?({:type, {:t, _, []}}, &1))

    for {:type, _, :map_field_exact, [{:atom, _, key}, value]} <- entries,
        key != :__struct__,
        into: %{},
        do: {key, type_to_string(value)}
  end

  defp type_to_string(type) do
    {:"::", _, [_name, quoted]} = Code.Typespec.type_to_quoted({:printed, type, []})

    Macro.to_string(quoted)
  end

  defp define(opts) do
    name = Module.concat(Core.StructTest, :"Generated#{System.unique_integer([:positive])}")

    Code.eval_quoted(
      quote do
        defmodule unquote(name) do
          alias Core.StructFixture
          alias Core.StructFixture.Name

          use Core.Struct, unquote(opts)
        end
      end
    )
  end
end
