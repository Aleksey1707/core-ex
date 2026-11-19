defmodule Core.FieldTest do
  use ExUnit.Case, async: true

  alias Core.Field
  alias Core.PrimFixture.Personal

  defmodule Name do
    @moduledoc false

    use Core.Prim.String,
      name: "Имя",
      min_len: 1,
      max_len: 50
  end

  defmodule PersonID do
    @moduledoc false

    use Core.Prim.UUID,
      name: "Идентификатор лица",
      version: 7
  end

  defmodule Step do
    @moduledoc false

    use Core.Struct,
      fields: [
        owner_id: [prim: PersonID],
        recipient: [prim: Personal, personal: true]
      ]
  end

  defmodule UnionFixture do
    @moduledoc false

    def types, do: [Core.StructFixture.Point, Personal]
  end

  defmodule Raw do
    @moduledoc false

    def __core_fields__, do: []
  end

  describe "declare!/3" do
    test "поле структуры — имя, вид и необязательность; default: ставит Core.Struct" do
      assert [
               %Field{
                 name: :a,
                 wire: "a",
                 spec: {:prim, Name},
                 optional?: false,
                 default: :none,
                 personal: nil,
                 subject: nil
               },
               %Field{name: :b, optional?: true, default: :none}
             ] =
               Field.declare!(
                 [a: [prim: Name], b: [prim: Name, optional: true]],
                 :struct,
                 "Struct: fields"
               )

      assert [%Field{name: :c, default: {:default, 3}}] =
               [c: [type: :integer]]
               |> Field.declare!(:struct, "Struct: fields")
               |> Core.Struct.default!(c: 3)
    end

    test "wire-ключ поля нагрузки" do
      assert [%Field{name: :a, wire: "bee"}] = Field.declare!([a: [prim: Name, wire: "bee"]], :payload, "P")
    end

    test "нагрузка: personal: и адрес субъекта" do
      assert [
               %Field{name: :phone, personal: true, subject: {:payload, :person_id}},
               %Field{name: :person_id, personal: nil, subject: nil},
               %Field{name: :local, subject: {:local, :person_id}},
               %Field{name: :holder, subject: :aggregate_id}
             ] =
               Field.declare!(
                 [
                   phone: [prim: Personal, personal: true, subject: {:payload, :person_id}],
                   person_id: [prim: PersonID],
                   local: [prim: Name, subject: {:local, :person_id}],
                   holder: [prim: Name, subject: :aggregate_id]
                 ],
                 :payload,
                 "Es.Event.Payload: fields"
               )
    end

    test "нагрузка: имя поля субъектом — адрес поля нагрузки" do
      assert [%Field{subject: nil}, %Field{subject: {:payload, :person_id}}] =
               Field.declare!([person_id: [prim: PersonID], contact: [prim: Name, subject: :person_id]], :payload, "P")
    end

    test "personal: false не оборачивает вид и не снимает флаг Prim" do
      assert [%Field{personal: false, spec: {:prim, Personal}}] =
               Field.declare!([a: [prim: Personal, personal: false]], :struct, "S")
    end

    test "personal: у элемента list: и значения map: — вложенное место" do
      assert [
               %Field{spec: {:list, {:personal, {:prim, Personal}}}},
               %Field{spec: {:set, {:personal, {:prim, Personal}}}},
               %Field{spec: {:map, {:type, :string}, {:personal, {:prim, Personal}}}}
             ] =
               Field.declare!(
                 [
                   tags: [list: [prim: Personal, personal: true]],
                   roles: [set: [prim: Personal, personal: true]],
                   contacts: [map: [key: [type: :string], value: [prim: Personal, personal: true]]]
                 ],
                 :struct,
                 "S"
               )
    end

    test "personal: у ключа map: — место поднимается до словаря" do
      fields =
        Field.declare!(
          [contacts: [map: [key: [type: :string, personal: true], value: [prim: Name]]]],
          :struct,
          "S"
        )

      assert [%Field{spec: {:map, {:personal, {:type, :string}}, {:prim, Name}}} = field] = fields
      assert Field.personal_places(fields, []) == [%{path: [field.name], subject: :aggregate_id}]
    end

    test "personal: — boolean" do
      assert_raise CompileError, ~r/^S: a: personal: ожидается boolean, получено :yes$/, fn ->
        Field.declare!([a: [prim: Personal, personal: :yes]], :struct, "S")
      end
    end

    test "неизвестный ключ — CompileError с именем хоста и поля" do
      assert_raise CompileError, ~r/^Struct: fields: a: неизвестные ключи \[:foo\]$/, fn ->
        Field.declare!([a: [prim: Name, foo: 1]], :struct, "Struct: fields")
      end
    end

    test "ключ вне роли — CompileError с именем хоста и поля" do
      assert_raise CompileError, ~r/^Labels.Fields: fields: a: неизвестные ключи \[:default\]$/, fn ->
        Field.declare!([a: [prim: Name, default: "x"]], :labels, "Labels.Fields: fields")
      end

      assert_raise CompileError, ~r/^Labels.Fields: fields: a: неизвестные ключи \[:subject\]$/, fn ->
        Field.declare!([a: [prim: Name, subject: :aggregate_id]], :labels, "Labels.Fields: fields")
      end
    end

    test "семейство вариантов полей не объявляет" do
      assert_raise CompileError, ~r/^Union: variants: у семейства вариантов полей нет$/, fn ->
        Field.declare!([a: [prim: Name]], :union, "Union: variants")
      end
    end
  end

  describe "introspect/1" do
    test "IR структуры — поля struct'а в порядке объявления" do
      for struct <- [Core.StructFixture.Wide, Step] do
        assert Enum.map(Field.introspect(struct), & &1.name) ==
                 Enum.map(struct.__info__(:struct), & &1.field) -- [:__struct__]
      end
    end

    test "IR нагрузки события «было → стало»" do
      payload = Core.DerivedFixture.Event.Renamed.Payload

      assert [
               %Field{name: :old_value, spec: {:prim, Core.EventFixture.Name}, optional?: false, personal: nil},
               %Field{name: :new_value, spec: {:prim, Core.EventFixture.Name}, optional?: false, personal: nil}
             ] = Field.introspect(payload)
    end

    test "IR не попадает в @type t структуры" do
      {:ok, types} = Code.Typespec.fetch_types(Core.StructFixture.Point)

      refute inspect(types) =~ "Core.Field"
    end

    test "модуль без протокола интроспекции" do
      assert Field.introspect(Enum) == nil
      assert Field.introspect(Core.FieldTest) == nil
    end

    test "протокол читается у любого модуля, а не только у собранного use" do
      assert Field.introspect(Core.FieldTest.Raw) == []
    end
  end

  describe "read_typespec/1 и write_typespec/1" do
    test "тип чтения добавляет уничтоженное значение на ПДн-местах, тип записи — нет" do
      fields =
        Field.declare!(
          [
            holder: [prim: Personal, personal: true],
            note: [prim: Name, optional: true],
            tags: [list: [prim: Personal]]
          ],
          :struct,
          "S"
        )

      assert type(Field.read_typespec(fields), :holder) =~ "Core.Es.Personal.Destroyed.t()"
      assert type(Field.read_typespec(fields), :tags) =~ "Core.Es.Personal.Destroyed.t()"
      assert type(Field.read_typespec(fields), :note) =~ "nil"
      refute type(Field.write_typespec(fields), :holder) =~ "Destroyed"
      refute type(Field.write_typespec(fields), :tags) =~ "Destroyed"
    end

    test "тип записи ссылается на write_t() сущности, тип чтения — на t()" do
      fields = Field.declare!([point: [entity: Core.StructFixture.Point]], :struct, "S")

      assert type(Field.read_typespec(fields), :point) == "Core.StructFixture.Point.t()"
      assert type(Field.write_typespec(fields), :point) == "Core.StructFixture.Point.write_t()"
    end

    test "entity: View — тип записи ссылается на существующий write_t() представления" do
      fields = Field.declare!([row: [entity: Core.ViewFixture.Nested]], :struct, "S")

      assert type(Field.read_typespec(fields), :row) == "Core.ViewFixture.Nested.t()"
      assert type(Field.write_typespec(fields), :row) == "Core.ViewFixture.Nested.write_t()"

      assert {:ok, types} = Code.Typespec.fetch_types(Core.ViewFixture.Nested)
      assert Enum.any?(types, &match?({:type, {:write_t, _, []}}, &1))
    end

    test "union: — тип записи из вариантов семейства, тип чтения — struct()" do
      fields = Field.declare!([shape: [union: UnionFixture]], :struct, "S")

      assert type(Field.read_typespec(fields), :shape) == "struct()"

      assert type(Field.write_typespec(fields), :shape) ==
               "Core.StructFixture.Point.write_t() | Core.PrimFixture.Personal.t()"
    end

    test "ПДн-лист set: и ключа map: поднимает Destroyed к контейнеру" do
      fields =
        Field.declare!(
          [
            roles: [set: [prim: Personal]],
            by_key: [map: [key: [type: :string, personal: true], value: [prim: Name]]]
          ],
          :struct,
          "S"
        )

      assert type(Field.read_typespec(fields), :roles) ==
               "MapSet.t(Core.PrimFixture.Personal.t()) | Core.Es.Personal.Destroyed.t()"

      assert type(Field.read_typespec(fields), :by_key) ==
               "%{optional(String.t()) => Core.FieldTest.Name.t()} | Core.Es.Personal.Destroyed.t()"
    end
  end

  describe "personal_places/2" do
    test "места верхнего уровня, элемента списка, множества и значения словаря" do
      fields =
        Field.declare!(
          [
            meta: [prim: Personal, personal: true],
            steps: [list: [entity: Step]],
            tags: [set: [prim: Personal]],
            contacts: [map: [key: [type: :string], value: [prim: Personal]]],
            plain: [list: [prim: Name]]
          ],
          :struct,
          "S"
        )

      assert Field.personal_places(fields, []) == [
               %{path: [:meta], subject: :aggregate_id},
               %{path: [:steps, :each, :recipient], subject: :aggregate_id},
               %{path: [:tags], subject: :aggregate_id},
               %{path: [:contacts, :each], subject: :aggregate_id}
             ]
    end

    test "personal: false не понижает персональный Prim" do
      fields = Field.declare!([flag: [prim: Personal, personal: false]], :struct, "S")

      assert Field.personal_places(fields, []) == [%{path: [:flag], subject: :aggregate_id}]
    end

    test "personal: true останавливает спуск" do
      fields = Field.declare!([step: [entity: Step, personal: true]], :struct, "S")

      assert Field.personal_places(fields, []) == [%{path: [:step], subject: :aggregate_id}]
    end

    test "ближайший subject: перекрывает внешний, локальный — соседнее поле" do
      fields =
        Field.declare!(
          [
            person_id: [prim: PersonID],
            phone: [prim: Personal, personal: true, subject: {:local, :person_id}],
            note: [prim: Personal, subject: {:payload, :person_id}],
            meta: [prim: Personal, personal: true]
          ],
          :payload,
          "P"
        )

      assert Field.personal_places(fields, []) == [
               %{path: [:phone], subject: {:path, [:person_id]}},
               %{path: [:note], subject: {:path, [:person_id]}},
               %{path: [:meta], subject: :aggregate_id}
             ]
    end
  end

  describe "inspect_hidden/1" do
    test "скрывается только поле, чьё значение целиком ПДн-место" do
      fields =
        Field.declare!(
          [
            holder: [prim: Personal, personal: true],
            secret: [prim: Personal],
            tags: [list: [prim: Personal]],
            meta: [prim: Name]
          ],
          :struct,
          "S"
        )

      assert Field.inspect_hidden(fields) == [:holder, :secret]
    end
  end

  describe "inspect_places/1" do
    test "пути мест поля, элемента списка и контейнера-эскалации" do
      fields =
        Field.declare!(
          [
            holder: [prim: Personal, personal: true],
            tags: [list: [prim: Personal]],
            roles: [set: [prim: Personal]],
            plain: [list: [prim: Name]]
          ],
          :struct,
          "S"
        )

      assert Field.inspect_places(fields) == %{holder: [[]], tags: [[:each]], roles: [[]]}
    end
  end

  describe "обход вида" do
    test "children/1 и values/1 не заходят в ключ словаря" do
      map = {:map, {:type, :string}, {:prim, Personal}}

      assert Field.children(map) == [{:type, :string}, {:prim, Personal}]
      assert Field.values(map) == [{:prim, Personal}]
      assert Field.children({:personal, {:prim, Personal}}) == [{:prim, Personal}]
      assert Field.children({:prim, Personal}) == []
    end

    test "walk/3 — вид и его вложенные виды" do
      spec = {:list, {:prim, Personal}}

      assert Field.walk(spec, [], fn spec, acc -> [spec | acc] end) == [
               {:prim, Personal},
               {:list, {:prim, Personal}}
             ]
    end
  end

  # ---

  defp type(typespec, name), do: Macro.to_string(Keyword.fetch!(typespec, name))
end
