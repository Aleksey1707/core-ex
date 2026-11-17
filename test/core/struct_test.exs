defmodule Core.StructTest do
  use ExUnit.Case, async: true

  alias Core.StructFixture
  alias Core.StructFixture.Name
  alias Core.StructFixture.Wide

  describe "use Core.Struct" do
    test "defstruct — все поля, значение nil" do
      assert Map.from_struct(struct(Wide)) ==
               Map.new(
                 ~w(name note status point shape tags matrix roles grid stock by_status count title attrs)a,
                 &{&1, nil}
               )
    end

    test "struct собирается литералом, Prim лежит в поле сам" do
      title = StructFixture.Nested.Title.new!("Отгрузка")

      assert %StructFixture.Nested{title: ^title} = %StructFixture.Nested{title: title}
    end

    test "обязательны все поля, и optional: тоже" do
      assert_raise ArgumentError,
                   ~r/\[:name, :note, :status, :point, :shape, :tags, :matrix, :roles, :grid, :stock, :by_status, :count, :title, :attrs\]/,
                   fn -> Code.eval_string("%Core.StructFixture.Wide{}") end
    end
  end

  describe "default:" do
    test "ключ с default: можно не указывать, остальные обязательны" do
      mod = define(fields: [name: [prim: Name], count: [type: :integer, default: 0]])
      name = Name.new!("Склад")

      assert %{name: ^name, count: 0} = struct!(mod, name: name)
      assert_raise ArgumentError, ~r/the following keys must also be given.*\[:name\]/, fn -> struct!(mod, []) end
    end

    test "значение каждого вида — выражение, вычисленное при сборке" do
      mod =
        define(
          quote do
            [
              fields: [
                name: [prim: Name, default: Name.new!("Склад")],
                status: [enum: StructFixture.Status, default: :new],
                point: [entity: StructFixture.Point, default: %StructFixture.Point{x: 1}],
                shape: [union: StructFixture.Shape, default: %StructFixture.Point{x: 2}],
                tags: [list: [prim: Name], default: [Name.new!("а"), Name.new!("б")]],
                matrix: [list: [list: [type: :integer]], default: [[1], []]],
                roles: [set: [prim: Name], default: MapSet.new([Name.new!("а")])],
                grid: [set: [set: [type: :integer]], default: MapSet.new()],
                stock: [map: [key: [prim: Name], value: [type: :integer]], default: %{Name.new!("а") => 1}],
                empty: [map: [key: [enum: StructFixture.Status], value: [set: [type: :integer]]], default: %{}],
                count: [type: :pos_integer, default: 3 * 7],
                title: [type: :string, default: "без названия"],
                flag: [type: :boolean, default: false],
                attrs: [type: :map, default: %{"k" => 1}],
                note: [prim: Name, optional: true, default: nil]
              ]
            ]
          end
        )

      assert struct!(mod, []) == %{
               __struct__: mod,
               name: Name.new!("Склад"),
               status: :new,
               point: %StructFixture.Point{x: 1},
               shape: %StructFixture.Point{x: 2},
               tags: [Name.new!("а"), Name.new!("б")],
               matrix: [[1], []],
               roles: MapSet.new([Name.new!("а")]),
               grid: MapSet.new(),
               stock: %{Name.new!("а") => 1},
               empty: %{},
               count: 21,
               title: "без названия",
               flag: false,
               attrs: %{"k" => 1},
               note: nil
             }
    end

    test "default: читает атрибут модуля, объявленный выше use" do
      {{:module, mod, _binary, _result}, _binding} =
        Code.eval_quoted(
          quote do
            defmodule Core.StructTest.AttrDefault do
              @warehouse Core.StructFixture.Name.new!("Склад")
              use Core.Struct, fields: [name: [prim: Core.StructFixture.Name, default: @warehouse]]
            end
          end
        )

      assert struct!(mod, []).name == Name.new!("Склад")
    end

    test "default: у Prim, вложенного выше use" do
      {{:module, mod, _binary, _result}, _binding} =
        Code.eval_string("""
        defmodule Core.StructTest.NestedDefault do
          defmodule Sku do
            use Core.Prim.String,
              name: "Артикул",
              max_len: 10
          end

          use Core.Struct, fields: [sku: [prim: Sku, default: Sku.new!("A1")]]
        end
        """)

      assert struct!(mod, []).sku == Core.StructTest.NestedDefault.Sku.new!("A1")
    end
  end

  describe "отказы default:" do
    test "сырое значение у prim: — CompileError" do
      assert_raise CompileError,
                   ~r/^Struct: fields: name: default: ожидается Prim Core.StructFixture.Name, получено "Склад"$/,
                   fn -> define(fields: [name: [prim: Name, default: "Склад"]]) end
    end

    test "чужой Prim — CompileError" do
      assert_raise CompileError, ~r/^Struct: fields: name: default: ожидается Prim Core.StructFixture.Name, /, fn ->
        define(quote(do: [fields: [name: [prim: Name, default: StructFixture.Nested.Title.new!("Отгрузка")]]]))
      end
    end

    test "атом вне Enum — CompileError" do
      assert_raise CompileError,
                   ~r/^Struct: fields: status: default: ожидается значение Core.StructFixture.Status, получено :gone$/,
                   fn -> define(fields: [status: [enum: StructFixture.Status, default: :gone]]) end
    end

    test "значение не того type: — CompileError" do
      assert_raise CompileError, ~r/^Struct: fields: count: default: ожидается pos_integer, получено -1$/, fn ->
        define(fields: [count: [type: :pos_integer, default: -1]])
      end

      assert_raise CompileError, ~r/^Struct: fields: attrs: default: ожидается map, получено %Core.StructFixture/, fn ->
        define(quote(do: [fields: [attrs: [type: :map, default: %StructFixture.Point{x: 1}]]]))
      end
    end

    test "чужой struct у entity: и не struct у union: — CompileError" do
      assert_raise CompileError,
                   ~r/^Struct: fields: point: default: ожидается %Core.StructFixture.Point\{\}, получено %\{x: 1\}$/,
                   fn -> define(quote(do: [fields: [point: [entity: StructFixture.Point, default: %{x: 1}]]])) end

      assert_raise CompileError,
                   ~r/^Struct: fields: shape: default: ожидается вариант Core.StructFixture.Shape, получено 1$/,
                   fn -> define(fields: [shape: [union: StructFixture.Shape, default: 1]]) end

      assert_raise CompileError,
                   ~r/^Struct: fields: shape: default: ожидается вариант Core.StructFixture.Shape, /,
                   fn ->
                     define(quote(do: [fields: [shape: [union: StructFixture.Shape, default: Name.new!("Склад")]]]))
                   end
    end

    test "list: — не список и элемент не того вида — CompileError" do
      assert_raise CompileError, ~r/^Struct: fields: tags: default: ожидается список, получено "а"$/, fn ->
        define(fields: [tags: [list: [prim: Name], default: "а"]])
      end

      assert_raise CompileError,
                   ~r/^Struct: fields: tags: default: ожидается Prim Core.StructFixture.Name, получено nil$/,
                   fn ->
                     define(fields: [tags: [list: [prim: Name], optional: true, default: [nil]]])
                   end
    end

    test "set: — не MapSet и элемент не того вида — CompileError" do
      assert_raise CompileError, ~r/^Struct: fields: roles: default: ожидается MapSet, получено \[\]$/, fn ->
        define(fields: [roles: [set: [prim: Name], default: []]])
      end

      assert_raise CompileError,
                   ~r/^Struct: fields: roles: default: ожидается Prim Core.StructFixture.Name, получено "а"$/,
                   fn -> define(quote(do: [fields: [roles: [set: [prim: Name], default: MapSet.new(["а"])]]])) end

      assert_raise CompileError,
                   ~r/^Struct: fields: grid: default: ожидается integer, получено "1"$/,
                   fn ->
                     define(
                       quote(
                         do: [fields: [grid: [set: [set: [type: :integer]], default: MapSet.new([MapSet.new(["1"])])]]]
                       )
                     )
                   end
    end

    test "map: — не map, ключ или значение не того вида — CompileError" do
      assert_raise CompileError, ~r/^Struct: fields: stock: default: ожидается map, получено \[\]$/, fn ->
        define(fields: [stock: [map: [key: [prim: Name], value: [type: :integer]], default: []]])
      end

      assert_raise CompileError, ~r/^Struct: fields: stock: default: ожидается map, получено MapSet.new\(\[\]\)$/, fn ->
        define(quote(do: [fields: [stock: [map: [key: [prim: Name], value: [type: :integer]], default: MapSet.new()]]]))
      end

      assert_raise CompileError,
                   ~r/^Struct: fields: stock: default: ожидается Prim Core.StructFixture.Name, получено "а"$/,
                   fn ->
                     define(
                       quote(
                         do: [
                           fields: [stock: [map: [key: [prim: Name], value: [type: :integer]], default: %{"а" => 1}]]
                         ]
                       )
                     )
                   end

      assert_raise CompileError,
                   ~r/^Struct: fields: stock: default: ожидается integer, получено "1"$/,
                   fn ->
                     define(
                       quote(
                         do: [
                           fields: [
                             stock: [
                               map: [key: [prim: Name], value: [type: :integer]],
                               default: %{Name.new!("а") => "1"}
                             ]
                           ]
                         ]
                       )
                     )
                   end
    end

    test "map: — Prim personal: true в значении — CompileError" do
      assert_raise CompileError,
                   ~r/^Struct: fields: emails: default: значение Prim .*Email с personal: true или sensitive: /,
                   fn ->
                     Code.eval_string("""
                     defmodule Core.StructTest.SecretMap do
                       defmodule Email do
                         use Core.Prim.String,
                           name: "Почта",
                           max_len: 50,
                           personal: true
                       end

                       use Core.Struct,
                         fields: [emails: [map: [key: [type: :string], value: [prim: Email]],
                                           default: %{"a" => Email.new!("a@b.c")}]]
                     end
                     """)
                   end
    end

    test "set: — Prim personal: true в элементе — CompileError" do
      assert_raise CompileError,
                   ~r/^Struct: fields: emails: default: значение Prim .*Email с personal: true или sensitive: /,
                   fn ->
                     Code.eval_string("""
                     defmodule Core.StructTest.SecretSet do
                       defmodule Email do
                         use Core.Prim.String,
                           name: "Почта",
                           max_len: 50,
                           personal: true
                       end

                       use Core.Struct,
                         fields: [emails: [set: [prim: Email], default: MapSet.new([Email.new!("a@b.c")])]]
                     end
                     """)
                   end
    end

    test "default: nil без optional: true — CompileError" do
      assert_raise CompileError,
                   ~r/^Struct: fields: note: default: nil без optional: true — тип поля не допускает nil$/,
                   fn -> define(fields: [note: [prim: Name, default: nil]]) end
    end

    test "Prim personal: true или sensitive: — CompileError" do
      for flag <- ["personal: true", "sensitive: true"] do
        assert_raise CompileError,
                     ~r/^Struct: fields: email: default: значение Prim .*Email с personal: true или sensitive: /,
                     fn ->
                       Code.eval_string("""
                       defmodule Core.StructTest.Secret#{System.unique_integer([:positive])} do
                         defmodule Email do
                           use Core.Prim.String,
                             name: "Почта",
                             max_len: 50,
                             #{flag}
                         end

                         use Core.Struct, fields: [email: [prim: Email, default: Email.new!("a@b.c")]]
                       end
                       """)
                     end
      end
    end

    test "Prim personal: true внутри значения entity: — CompileError" do
      assert_raise CompileError,
                   ~r/^Struct: fields: box: default: значение Prim .*Email с personal: true или sensitive: /,
                   fn ->
                     Code.eval_string("""
                     defmodule Core.StructTest.SecretBox do
                       defmodule Email do
                         use Core.Prim.String,
                           name: "Почта",
                           max_len: 50,
                           personal: true
                       end

                       defmodule Box do
                         use Core.Struct, fields: [emails: [list: [prim: Email]]]
                       end

                       use Core.Struct, fields: [box: [entity: Box, default: struct!(Box, emails: [Email.new!("a@b.c")])]]
                     end
                     """)
                   end
    end

    test "default: nil у Prim personal: true — собирается" do
      {{:module, mod, _binary, _result}, _binding} =
        Code.eval_string("""
        defmodule Core.StructTest.PersonalNil do
          defmodule Email do
            use Core.Prim.String,
              name: "Почта",
              max_len: 50,
              personal: true
          end

          use Core.Struct, fields: [email: [prim: Email, optional: true, default: nil]]
        end
        """)

      assert struct!(mod, []).email == nil
    end
  end

  describe "events:" do
    test "ключ events можно не указывать: пустая коллекция событий" do
      name = Name.new!("Склад")

      assert %StructFixture.Events{name: ^name, events: []} = %StructFixture.Events{name: name}
      assert Core.Es.Events.empty?(%StructFixture.Events{name: name}.events)
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

    test "set: — MapSet.t типа элемента, и вложенный тоже", %{fields: fields} do
      assert fields[:roles] == "MapSet.t(Core.StructFixture.Name.t())"
      assert fields[:grid] == "MapSet.t(MapSet.t(integer())) | nil"
    end

    test "map: — map с типами ключа и значения, и вложенный тоже", %{fields: fields} do
      assert fields[:stock] == "%{optional(Core.StructFixture.Name.t()) => integer()}"

      assert fields[:by_status] ==
               "%{optional(Core.StructFixture.Status.t()) => %{optional(String.t()) => integer()}} | nil"
    end

    test "type: — тип примитива", %{fields: fields} do
      assert fields[:count] == "non_neg_integer()"
      assert fields[:title] == "String.t()"
    end

    test "optional: true добавляет | nil", %{fields: fields} do
      assert fields[:note] == "Core.StructFixture.Name.t() | nil"
      assert fields[:attrs] == "map() | nil"
    end

    test "default: тип не меняет: без optional: — T, с optional: — T | nil" do
      {:ok, types} = Code.Typespec.fetch_types(StructFixture.Defaults)

      assert struct_type_fields(types) == %{count: "integer()", note: "Core.StructFixture.Name.t() | nil"}
    end

    test "personal: true добавляет | Destroyed.t(), с optional: — ещё | nil" do
      {:ok, types} = Code.Typespec.fetch_types(StructFixture.Personal)
      fields = struct_type_fields(types)

      assert fields[:holder] == "Core.StructFixture.Name.t() | Core.Es.Personal.Destroyed.t()"
      assert fields[:phone] == "Core.StructFixture.Name.t() | Core.Es.Personal.Destroyed.t() | nil"
      assert fields[:point] == "Core.StructFixture.Point.t() | Core.Es.Personal.Destroyed.t()"
      assert fields[:open] == "Core.StructFixture.Name.t()"
    end

    test "personal: у поля вложенной сущности — в типе сущности, не в типе поля" do
      {:ok, types} = Code.Typespec.fetch_types(StructFixture.Recipient)

      assert struct_type_fields(types) == %{
               phone: "Core.StructFixture.Name.t() | Core.Es.Personal.Destroyed.t()",
               label: "Core.StructFixture.Name.t()"
             }

      {:ok, types} = Code.Typespec.fetch_types(StructFixture.Personal)

      assert struct_type_fields(types)[:recipients] == "[Core.StructFixture.Recipient.t()]"
    end

    test "personal: у элемента list: и значения map: — к типу элемента и значения" do
      {:ok, types} = Code.Typespec.fetch_types(StructFixture.Personal)
      fields = struct_type_fields(types)

      assert fields[:names] == "[Core.StructFixture.Name.t() | Core.Es.Personal.Destroyed.t()]"

      assert fields[:matrix] == "[[Core.StructFixture.Name.t() | Core.Es.Personal.Destroyed.t()]]"

      assert fields[:by_id] ==
               "%{optional(String.t()) => Core.StructFixture.Name.t() | Core.Es.Personal.Destroyed.t()}"
    end

    test "ПДн-лист set: и ключа map: поднимает место до контейнера" do
      {:ok, types} = Code.Typespec.fetch_types(StructFixture.Personal)
      fields = struct_type_fields(types)

      assert fields[:roles] == "MapSet.t(Core.PrimFixture.Personal.t()) | Core.Es.Personal.Destroyed.t()"

      assert fields[:by_key] ==
               "%{optional(String.t()) => Core.StructFixture.Name.t()} | Core.Es.Personal.Destroyed.t()"

      assert fields[:tags] == "[Core.StructFixture.Name.t()] | Core.Es.Personal.Destroyed.t()"
    end

    test "write_t — без Destroyed, entity: и element: проецируются на write_t()" do
      {:ok, types} = Code.Typespec.fetch_types(StructFixture.Personal)
      fields = struct_type_fields(types, :write_t)

      refute Enum.any?(fields, fn {_name, type} -> type =~ "Destroyed" end)

      assert fields[:holder] == "Core.StructFixture.Name.t()"
      assert fields[:phone] == "Core.StructFixture.Name.t() | nil"
      assert fields[:point] == "Core.StructFixture.Point.write_t()"
      assert fields[:recipients] == "[Core.StructFixture.Recipient.write_t()]"
      assert fields[:names] == "[Core.StructFixture.Name.t()]"
      assert fields[:matrix] == "[[Core.StructFixture.Name.t()]]"
      assert fields[:tags] == "[Core.StructFixture.Name.t()]"
      assert fields[:roles] == "MapSet.t(Core.PrimFixture.Personal.t())"
      assert fields[:by_key] == "%{optional(String.t()) => Core.StructFixture.Name.t()}"
      assert fields[:by_id] == "%{optional(String.t()) => Core.StructFixture.Name.t()}"
      assert fields[:open] == "Core.StructFixture.Name.t()"
    end

    test "без ПДн-мест write_t — буквально t()" do
      {:ok, types} = Code.Typespec.fetch_types(StructFixture.Wide)

      assert {:type, {:write_t, {:user_type, _meta, :t, []}, []}} =
               Enum.find(types, &match?({:type, {:write_t, _type, []}}, &1))
    end

    test "events: — поле events с типом коллекции событий семейства" do
      {:ok, types} = Code.Typespec.fetch_types(StructFixture.Events)

      assert struct_type_fields(types) == %{
               name: "Core.StructFixture.Name.t()",
               events: "Core.Es.Events.t(Core.EventFixture.Event.t())"
             }
    end

    test "Prim, вложенный выше use, — тип вложенного модуля" do
      {:ok, types} = Code.Typespec.fetch_types(StructFixture.Nested)

      assert struct_type_fields(types) == %{title: "Core.StructFixture.Nested.Title.t()"}
    end
  end

  describe "Inspect" do
    setup do
      recipient = struct!(StructFixture.Recipient, phone: phone("+7 999 000"), label: Name.new!("склад"))

      value =
        struct!(
          StructFixture.Inspectable,
          holder: Name.new!("открытое имя"),
          secret: phone("+7 111 111"),
          tags: [phone("+7 222 222"), phone("+7 333 333")],
          step: recipient,
          sealed: %StructFixture.Point{x: 42}
        )

      %{value: value}
    end

    test "значение ПДн-места не попадает в вывод, открытые поля видны", %{value: value} do
      output = inspect(value)

      refute output =~ "+7 111 111"
      refute output =~ "+7 222 222"
      refute output =~ "+7 333 333"
      refute output =~ "+7 999 000"
      refute output =~ "42"

      assert output =~ "открытое имя"
      assert output =~ "склад"
      assert output =~ "%Core.Es.Personal.Hidden{}"
    end

    test "скрываются все места списка, а не список целиком", %{value: value} do
      output = inspect(value)

      assert output =~ "tags: [%Core.Es.Personal.Hidden{}, %Core.Es.Personal.Hidden{}]"
    end

    test "уничтоженное значение печатается обычным struct'ом", %{value: value} do
      output = inspect(%{value | secret: %Core.Es.Personal.Destroyed{}})

      assert output =~ "%Core.Es.Personal.Destroyed{}"
    end
  end

  describe "отказы декларации" do
    test "map: — ключ без wire-строки, персональный ключ, без value: — CompileError" do
      assert_raise CompileError,
                   ~r/^Struct: fields: stock: map: key: ожидается вид с wire-строкой, получено \[type: :integer\]$/,
                   fn -> define(fields: [stock: [map: [key: [type: :integer], value: [type: :integer]]]]) end

      assert_raise CompileError,
                   ~r/^Struct: fields: phones: map: key: Prim Core.PrimFixture.Personal с personal: true или sensitive:/,
                   fn ->
                     define(fields: [phones: [map: [key: [prim: Core.PrimFixture.Personal], value: [type: :integer]]]])
                   end

      assert_raise CompileError, ~r/^Struct: fields: stock: map: ожидается \[key: спека, value: спека\]/, fn ->
        define(fields: [stock: [map: [key: [prim: Name]]]])
      end
    end

    test "wire: и subject: — часть декларации структуры" do
      mod = define(fields: [name: [prim: Name, wire: "title", subject: :aggregate_id]])

      assert [%Core.Codec.Field{name: :name, wire: "title", subject: :aggregate_id}] =
               Core.Codec.Field.struct_fields(mod)
    end

    test "destroyable: удалён — CompileError с указанием на personal: true" do
      assert_raise CompileError,
                   ~r/^Struct: fields: holder: destroyable: удалён — ПДн-место объявляет personal: true/,
                   fn -> define(fields: [holder: [prim: Name, destroyable: true]]) end

      assert_raise CompileError, ~r/^Struct: fields: holder: destroyable: удалён — /, fn ->
        define(fields: [holder: [prim: Name, destroyable: false]])
      end

      assert_raise CompileError, ~r/^Struct: fields: names: destroyable: удалён — /, fn ->
        define(fields: [names: [list: [prim: Name, destroyable: true]]])
      end

      assert_raise CompileError, ~r/^Struct: fields: by_id: destroyable: удалён — /, fn ->
        define(fields: [by_id: [map: [key: [type: :string], value: [prim: Name, destroyable: true]]]])
      end
    end

    test "default: у ПДн-поля проверяется как раньше" do
      assert_raise CompileError, ~r/^Struct: fields: holder: default: ожидается Prim Core.StructFixture.Name, /, fn ->
        define(fields: [holder: [prim: Name, personal: true, default: "Склад"]])
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
      assert_raise CompileError, ~r/^Struct: fields: name: ожидается литерал, получено Module.concat/, fn ->
        define(quote(do: [fields: [name: [prim: Module.concat(Core.StructFixture, Name)]]]))
      end
    end

    test "поле events в fields: рядом с events: — CompileError" do
      assert_raise CompileError,
                   ~r/^Struct: fields: events: поле events порождает events: Core.EventFixture.Event/,
                   fn ->
                     define(fields: [events: [type: :map]], events: Core.EventFixture.Event)
                   end
    end

    test "events: не семейство событий — CompileError" do
      assert_raise CompileError,
                   ~r/^Struct: events: ожидается семейство событий \(use Core.Es.Event.Family\), получено Core.EventFixture.Event.Codec$/,
                   fn -> define(fields: [name: [prim: Name]], events: Core.EventFixture.Event.Codec) end

      assert_raise CompileError, ~r/^Struct: events: модуль Core.StructFixture.Missing недоступен/, fn ->
        define(fields: [name: [prim: Name]], events: StructFixture.Missing)
      end
    end

    test "events: не литерал — «ожидается литерал»" do
      assert_raise CompileError, ~r/^Struct: events: ожидается литерал, получено @family$/, fn ->
        Code.eval_quoted(
          quote do
            defmodule Core.StructTest.AttrEvents do
              @family Core.EventFixture.Event
              use Core.Struct,
                fields: [name: [prim: Core.StructFixture.Name]],
                events: @family
            end
          end
        )
      end
    end

    test "опечатка в ключе — при раскрытии, с меткой" do
      assert_raise CompileError, ~r/^Struct: нет обязательных опций: \[:fields\]; неизвестные опции: \[:field\]$/, fn ->
        define(field: [name: [prim: Name]])
      end
    end
  end

  defp struct_type_fields(types, name \\ :t) do
    {:type, {^name, {:type, _, :map, entries}, []}} =
      Enum.find(types, &match?({:type, {^name, _, []}}, &1))

    for {:type, _, :map_field_exact, [{:atom, _, key}, value]} <- entries,
        key != :__struct__,
        into: %{},
        do: {key, type_to_string(value)}
  end

  defp phone(value), do: Core.PrimFixture.Personal.new!(value)

  defp type_to_string(type) do
    {:"::", _, [_name, quoted]} = Code.Typespec.type_to_quoted({:printed, type, []})

    Macro.to_string(quoted)
  end

  defp define(opts) do
    name = Module.concat(Core.StructTest, :"Generated#{System.unique_integer([:positive])}")

    {{:module, ^name, _binary, _result}, _binding} =
      Code.eval_quoted(
        quote do
          defmodule unquote(name) do
            alias Core.StructFixture
            alias Core.StructFixture.Name

            use Core.Struct, unquote(opts)
          end
        end
      )

    name
  end
end
