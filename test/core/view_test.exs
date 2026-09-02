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
    ViewFixture.Sample.new(
      Keyword.merge(
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
          payload: %{"measured_at" => "2024-06-01T12:00:00.123456Z"},
          marks: [%{code: "m1", at: @at, by: @uuid}],
          created_at: @at
        ],
        overrides
      )
    )
  end

  defp dump(view, codec \\ OutCodec), do: ViewFixture.Sample.Codec.dump(view, codec)

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

    test "jsonb переводится по спеке redump с точностью Prim" do
      assert %{"measured_at" => measured} = dump(view()).payload
      assert measured == OutCodec.dump(ViewFixture.MeasuredAt.new!(@measured_at))
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

    test "неизвестный скалярный тип" do
      assert_raise CompileError, ~r/неизвестный type:/, fn ->
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

    test "jsonb требует ссылку на функцию-спеку" do
      assert_raise CompileError, ~r/спеки redump/, fn ->
        define(fields: [payload: [jsonb: :spec]])
      end

      assert_raise CompileError, ~r/не объявлена/, fn ->
        define(fields: [payload: [jsonb: {Core.ViewFixture.Specs, :missing_spec}]])
      end
    end

    test "пустой и дублирующий список полей" do
      assert_raise CompileError, ~r/непустой keyword-список/, fn -> define(fields: []) end

      assert_raise CompileError, ~r/дубли ключей/, fn ->
        define(fields: [id: [prim: Core.ViewFixture.ID], id: [type: :string]])
      end
    end
  end

  defmodule LabelID do
    use Core.Prim.UUID, name: "Метка", version: 4, kind: :label
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
