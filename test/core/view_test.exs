defmodule Core.ViewTest do
  use ExUnit.Case, async: true

  alias Core.ViewFixture
  alias Core.ViewFixture.InCodec
  alias Core.ViewFixture.OutCodec

  @uuid "550e8400-e29b-41d4-a716-446655440000"
  @at ~U[2024-06-01 12:00:00Z]
  @measured_at ~U[2024-06-01 12:00:00.123456Z]

  defp nested do
    ViewFixture.Nested.new(id: @uuid, name: "Вложенное")
  end

  defp view(overrides \\ []) do
    ViewFixture.Sample.new(Keyword.merge(sample_opts(), overrides))
  end

  defp sample_opts do
    [
      id: @uuid,
      name: "Образец",
      status: :new,
      version: 1,
      active: true,
      weight: Decimal.new("10.5"),
      day: ~D[2024-06-01],
      nested: nested(),
      children: [nested()],
      tags: ~w(a b),
      payload: payload(),
      marks: [%{code: "m1", at: @at, by: @uuid}],
      created_at: @at
    ]
  end

  defp dump(view, codec \\ OutCodec), do: ViewFixture.Sample.Codec.dump(view, codec)

  defp payload, do: %{"measured_at" => "2024-06-01T12:00:00.123456Z"}

  defp json_roundtrip(value), do: Jason.decode!(Jason.encode!(value))

  describe "структура" do
    test "обязательные поля в @enforce_keys, optional — нет" do
      assert %ViewFixture.Sample{id: @uuid, status: :new, weight: nil} =
               ViewFixture.Sample.new(
                 id: @uuid,
                 name: "Образец",
                 status: :new,
                 version: 1,
                 active: true,
                 children: [],
                 tags: [],
                 payload: %{},
                 marks: [],
                 created_at: @at
               )
    end

    test "пропуск обязательного поля — ошибка" do
      assert_raise KeyError, fn -> ViewFixture.Sample.new(id: @uuid) end
    end

    test "неизвестное поле — ошибка" do
      assert_raise KeyError, ~r/не объявлены в представлении/, fn ->
        ViewFixture.Sample.new(Keyword.put(sample_opts(), :nmae, "Образец"))
      end
    end

    test "состав полей структуры равен объявленному" do
      keys =
        view()
        |> Map.from_struct()
        |> Map.keys()
        |> Enum.sort()

      assert keys == Enum.sort(declared_fields())
    end
  end

  describe "кодек представления" do
    test "формат полей совпадает с дампом соответствующего Prim" do
      dumped = dump(view())

      assert dumped.id == OutCodec.dump(ViewFixture.ID.new!(@uuid))
      assert dumped.created_at == OutCodec.dump(ViewFixture.CreatedAt.new!(@at))
      assert dumped.weight == OutCodec.dump(ViewFixture.Weight.new!(Decimal.new("10.5")))
      assert dumped.day == OutCodec.dump(ViewFixture.Day.new!(~D[2024-06-01]))
    end

    test "композит над приводимой базой дампится как база" do
      refs = ViewFixture.Refs.new(id: @uuid, ref: @uuid)

      for codec <- [OutCodec, InCodec] do
        dumped = ViewFixture.Refs.Codec.dump(refs, codec)

        assert dumped.ref == dumped.id
      end
    end

    test "формат зависит от профиля кодека" do
      assert dump(view(), InCodec).id == InCodec.dump(ViewFixture.ID.new!(@uuid))
      refute dump(view(), InCodec).id == dump(view()).id
    end

    test "enum, скаляры и строковые Prim уходят как есть" do
      dumped = dump(view())

      assert dumped.status == :new
      assert dumped.version == 1
      assert dumped.active == true
      assert dumped.name == "Образец"
      assert dumped.tags == ~w(a b)
    end

    test "nil в optional-полях остаётся nil" do
      dumped = dump(view(weight: nil, day: nil, nested: nil, closed_at: nil))

      assert %{weight: nil, day: nil, nested: nil, closed_at: nil} = dumped
    end

    test "вложенный View дампится своим кодеком" do
      dumped = dump(view())

      assert dumped.nested == OutCodec.dump(nested())
      assert dumped.children == [OutCodec.dump(nested())]
    end

    test "форма дампится по объявленным полям" do
      assert [%{code: "m1", at: at, by: by}] = dump(view()).marks
      assert at == OutCodec.dump(ViewFixture.CreatedAt.new!(@at))
      assert by == OutCodec.dump(ViewFixture.ID.new!(@uuid))
    end

    test "optional-поле формы отсутствует в map — берётся nil" do
      assert [%{code: "m1", by: nil}] = dump(view(marks: [%{code: "m1", at: @at}])).marks
    end

    test "форма со строковыми ключами дампится как с атомными" do
      string_keys = %{"code" => "m1", "at" => @at, "by" => @uuid}

      assert dump(view(marks: [string_keys])).marks == dump(view()).marks
    end

    test "jsonb переводится по спеке redump с точностью Prim" do
      assert %{"measured_at" => measured} = dump(view()).payload
      assert measured == OutCodec.dump(ViewFixture.MeasuredAt.new!(@measured_at))
    end

    test "не-map на месте формы уходит как есть" do
      assert dump(view(marks: ["m1"])).marks == ["m1"]
    end

    test "не-список на месте list: уходит как есть" do
      assert dump(view(tags: "a,b")).tags == "a,b"
    end

    test "jsonb-массив дампится поэлементно" do
      listy = ViewFixture.Listy.new(payloads: [payload(), payload()], marks: [])

      assert [%{"measured_at" => measured}, %{"measured_at" => same}] =
               ViewFixture.Listy.Codec.dump(listy, OutCodec).payloads

      assert measured == OutCodec.dump(ViewFixture.MeasuredAt.new!(@measured_at))
      assert same == measured
    end

    test "jsonb: Type и list: [jsonb: Type] переводятся по выведенной спеке типа" do
      reading = %ViewFixture.Reading{
        measured_at: ViewFixture.MeasuredAt.new!(@measured_at),
        weight: ViewFixture.Weight.new!(Decimal.new("10.5")),
        status: :done
      }

      stored = json_roundtrip(InCodec.dump(reading))
      entry = %{"reading" => stored, "readings" => [stored]}
      typed = ViewFixture.Typed.new(reading: stored, readings: [stored, stored], entries: [entry])
      expected = json_roundtrip(OutCodec.dump(reading))

      assert %{
               reading: ^expected,
               readings: [^expected, ^expected],
               entries: [%{reading: ^expected, readings: [^expected]}]
             } = ViewFixture.Typed.Codec.dump(typed, OutCodec)

      assert %{reading: nil} = ViewFixture.Typed.Codec.dump(ViewFixture.Typed.new(readings: [], entries: []), OutCodec)
    end

    test "type: :map уходит как есть, nil проходит" do
      attrs = %{"a" => 1, "b" => %{"c" => ["d"]}}
      entry = %{"attrs" => attrs}
      free = ViewFixture.Free.new(attrs: attrs, extra: nil, items: [attrs, %{}], entries: [entry])

      assert %{attrs: ^attrs, extra: nil, items: [^attrs, %{}], entries: [%{attrs: ^attrs}]} =
               OutCodec.dump(free)

      assert %{extra: ^attrs} = OutCodec.dump(%{free | extra: attrs})
    end

    test "форма внутри формы дампится своим набором полей" do
      listy = ViewFixture.Listy.new(payloads: [], marks: [%{code: "m1", inner: %{at: @at}}])

      assert [%{code: "m1", inner: %{at: at}}] =
               ViewFixture.Listy.Codec.dump(listy, OutCodec).marks

      assert at == OutCodec.dump(ViewFixture.CreatedAt.new!(@at))
    end

    test "плагин остаётся dump-only" do
      assert_raise ArgumentError, fn -> OutCodec.load(ViewFixture.Sample, %{}) end
    end
  end

  describe "точность сгенерированных типов" do
    setup do
      {:ok, types} = Code.Typespec.fetch_types(ViewFixture.Sample)
      %{fields: struct_type_fields(types)}
    end

    test "Prim-поля типизированы по kind своего Prim", %{fields: fields} do
      assert "String.t()" = fields[:id]
      assert "DateTime.t()" = fields[:created_at]
      assert "Decimal.t() | nil" = fields[:weight]
      assert "Date.t() | nil" = fields[:day]
    end

    test "композит над приводимой базой типизирован по kind leaf-примитива" do
      {:ok, types} = Code.Typespec.fetch_types(ViewFixture.Refs)
      fields = struct_type_fields(types)

      assert fields[:ref] == fields[:id]
      assert fields[:own_kind] == "#{fields[:id]} | nil"
    end

    test "enum, скаляры и вложенные структуры типизированы точно", %{fields: fields} do
      assert fields[:status] =~ "Status.t()"
      assert "pos_integer()" = fields[:version]
      assert "boolean()" = fields[:active]
      assert fields[:nested] =~ "Nested.t() | nil"
      assert fields[:children] =~ "[Core.ViewFixture.Nested.t()]"
      assert "[String.t()]" = fields[:tags]
      assert "map()" = fields[:payload]
      assert "[mark()]" = fields[:marks]
    end

    test "jsonb-массив и вложенная форма типизированы точно" do
      {:ok, types} = Code.Typespec.fetch_types(ViewFixture.Listy)
      fields = struct_type_fields(types)

      assert "[map()]" = fields[:payloads]
      assert "[mark()]" = fields[:marks]
    end

    test "jsonb: Type типизирован как jsonb: {Mod, :fun}" do
      {:ok, types} = Code.Typespec.fetch_types(ViewFixture.Typed)
      fields = struct_type_fields(types)

      assert "map() | nil" = fields[:reading]
      assert "[map()]" = fields[:readings]
    end

    test "type: :map типизирован map()" do
      {:ok, types} = Code.Typespec.fetch_types(ViewFixture.Free)
      fields = struct_type_fields(types)

      assert "map()" = fields[:attrs]
      assert "map() | nil" = fields[:extra]
      assert "[map()]" = fields[:items]

      assert {:type, {:entry, form_type, []}} =
               Enum.find(types, &match?({:type, {:entry, _, []}}, &1))

      assert type_to_string(form_type) =~ "attrs: map()"
    end

    test "форма получает именованный тип" do
      {:ok, types} = Code.Typespec.fetch_types(ViewFixture.Sample)

      assert {:type, {:mark, form_type, []}} =
               Enum.find(types, &match?({:type, {:mark, _, []}}, &1))

      printed = type_to_string(form_type)
      assert printed =~ "code: String.t()"
      assert printed =~ "at: DateTime.t()"
      assert printed =~ "by: String.t() | nil"
    end
  end

  describe "проверки декларации" do
    test "sensitive Prim не допускается" do
      assert_raise CompileError, ~r/sensitive/, fn ->
        define(fields: [secret: [prim: Core.PrimFixture.Sensitive]])
      end
    end

    test "sensitive Prim с кастомным kind — отказ по sensitive" do
      assert_raise CompileError, ~r/SensitiveLabel объявлен sensitive/, fn ->
        define(fields: [secret: [prim: Core.PrimFixture.SensitiveLabel]])
      end
    end

    test "personal Prim допускается и показывается" do
      {{:module, mod, _, _}, _} = define(fields: [phone: [prim: Core.PrimFixture.Personal]])

      codec = Module.concat(mod, Codec)

      assert codec.dump(mod.new(phone: "+79991234567"), OutCodec) == %{phone: "+79991234567"}
    end

    test "Prim с personal и sensitive не допускается" do
      assert_raise CompileError, ~r/sensitive/, fn ->
        define(fields: [document: [prim: Core.PrimFixture.PersonalSensitive]])
      end
    end

    test "не-Enum в enum: не допускается" do
      assert_raise CompileError, ~r/не Core.Enum/, fn ->
        define(fields: [status: [enum: DateTime]])
      end
    end

    test "не-модуль в prim: не допускается" do
      assert_raise CompileError, ~r/ожидался модуль/, fn ->
        define(fields: [id: [prim: "Core.ViewFixture.ID"]])
      end
    end

    test "не-Prim в prim: не допускается" do
      assert_raise CompileError, ~r/не Prim/, fn ->
        define(fields: [id: [prim: DateTime]])
      end
    end

    test "Prim с кастомным kind не типизируется" do
      assert_raise CompileError, ~r/типизировать нечем/, fn ->
        define(fields: [id: [prim: Core.ViewTest.LabelID]])
      end
    end

    test "композит над Prim с кастомным kind не типизируется" do
      assert_raise CompileError, ~r/LabelRef \(leaf Core.ViewTest.LabelID\) kind :label — типизировать нечем/, fn ->
        define(fields: [ref: [prim: Core.ViewTest.LabelRef]])
      end
    end

    test "неизвестный type:" do
      assert_raise CompileError, ~r/неизвестный type:.*:map/, fn ->
        define(fields: [n: [type: :float]])
      end
    end

    test "нужен ровно один kind-ключ" do
      assert_raise CompileError, ~r/ровно один из/, fn ->
        define(fields: [id: [prim: Core.ViewFixture.ID, type: :string]])
      end

      assert_raise CompileError, ~r/ровно один из/, fn ->
        define(fields: [id: [optional: true]])
      end
    end

    test "необъявленная форма" do
      assert_raise CompileError, ~r/не объявлена в forms:/, fn ->
        define(fields: [items: [list: [form: :item]]])
      end
    end

    test "неиспользуемая форма" do
      assert_raise CompileError, ~r/не используются/, fn ->
        define(
          fields: [id: [prim: Core.ViewFixture.ID]],
          forms: [item: [code: [type: :string]]]
        )
      end
    end

    test "форма, достижимая только из неиспользуемой формы, тоже неиспользуема" do
      assert_raise CompileError, ~r/\[:outer, :inner\]/, fn ->
        define(
          fields: [id: [prim: Core.ViewFixture.ID]],
          forms: [
            outer: [inner: [form: :inner]],
            inner: [code: [type: :string]]
          ]
        )
      end
    end

    test "не-View в view: не допускается" do
      assert_raise CompileError, ~r/не Core.View/, fn ->
        define(fields: [nested: [view: DateTime]])
      end
    end

    test "jsonb требует модуль типа или ссылку на функцию-спеку" do
      assert_raise CompileError, ~r/поле payload: jsonb: — модуль типа или \{Модуль, :функция\} спеки redump/, fn ->
        define(fields: [payload: [jsonb: "spec"]])
      end

      assert_raise CompileError, ~r/поле payload: :spec недоступен/, fn ->
        define(fields: [payload: [jsonb: :spec]])
      end

      assert_raise CompileError, ~r/не объявлена/, fn ->
        define(fields: [payload: [jsonb: {Core.ViewFixture.Specs, :missing_spec}]])
      end
    end

    test "jsonb: Prim или Core.Enum — CompileError" do
      assert_raise CompileError, ~r/поле payload: jsonb: .*ViewFixture.Weight — Prim/, fn ->
        define(fields: [payload: [jsonb: Core.ViewFixture.Weight]])
      end

      assert_raise CompileError, ~r/поле payloads: jsonb: .*ViewFixture.Status — Core.Enum/, fn ->
        define(fields: [payloads: [list: [jsonb: Core.ViewFixture.Status]]])
      end
    end

    test "forms: — keyword-список без дублей" do
      assert_raise CompileError, ~r/forms: должен быть keyword-списком/, fn ->
        define(fields: [id: [prim: Core.ViewFixture.ID]], forms: :mark)
      end

      assert_raise CompileError, ~r/View: forms: повторяются \[:mark\]/, fn ->
        define(
          fields: [mark: [form: :mark]],
          forms: [mark: [code: [type: :string]], mark: [code: [type: :string]]]
        )
      end

      assert_raise CompileError, ~r/View: форма mark: повторяются \[:code\]/, fn ->
        define(
          fields: [mark: [form: :mark]],
          forms: [mark: [code: [type: :string], code: [type: :boolean]]]
        )
      end
    end

    test "optional: — boolean и задаётся у самого поля" do
      assert_raise CompileError, ~r/optional: — boolean/, fn ->
        define(fields: [id: [prim: Core.ViewFixture.ID, optional: "да"]])
      end

      assert_raise CompileError, ~r/optional: задаётся у самого поля/, fn ->
        define(fields: [tags: [list: [type: :string, optional: true]]])
      end
    end

    test "вложенность списков глубже допустимой" do
      assert_raise CompileError, ~r/вложенность списков/, fn ->
        define(fields: [deep: [list: [list: [list: [list: [list: [type: :string]]]]]]])
      end
    end

    test "пустой и дублирующий список полей" do
      assert_raise CompileError, ~r/непустой keyword-список/, fn -> define(fields: []) end

      assert_raise CompileError, ~r/View: fields: повторяются \[:id\]/, fn ->
        define(fields: [id: [prim: Core.ViewFixture.ID], id: [type: :string]])
      end
    end
  end

  defmodule LabelID do
    use Core.Prim.UUID, name: "Метка", version: 4, kind: :label
  end

  defmodule LabelRef do
    use Core.Prim.Compose,
      name: "Ссылка на метку",
      of: Core.ViewTest.LabelID
  end

  # ---

  defp declared_fields do
    ~w(id name status version active weight day nested children tags payload marks
       created_at closed_at)a
  end

  defp struct_type_fields(types) do
    {:type, {:t, {:type, _, :map, entries}, []}} =
      Enum.find(types, &match?({:type, {:t, _, []}}, &1))

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
    Code.eval_quoted(
      quote do
        defmodule unquote(
                    Module.concat(
                      Core.ViewTest,
                      :"Generated#{System.unique_integer([:positive])}"
                    )
                  ) do
          use Core.View, unquote(opts)
        end
      end
    )
  end
end
