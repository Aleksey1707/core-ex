defmodule Core.Codec.PluginRedumpTest do
  use ExUnit.Case, async: true

  alias Core.Codec.Redump
  alias Core.Prim
  alias Core.PrimFixture.Personal
  alias Core.PrimFixture.Sensitive

  defmodule ID do
    use Prim.UUID,
      name: "Идентификатор",
      version: 4
  end

  defmodule At do
    use Prim.DateTime, name: "Момент"
  end

  defmodule Weight do
    use Prim.Decimal,
      name: "Вес",
      min: 0
  end

  defmodule Day do
    use Prim.Date, name: "Дата"
  end

  defmodule Name do
    use Prim.String,
      name: "Имя",
      min_len: 1,
      max_len: 50
  end

  defmodule Label do
    use Prim.UUID,
      name: "Метка",
      version: 4,
      kind: :label
  end

  defmodule Status do
    @moduledoc """
    | Значение | Описание |
    |---|---|
    | `:draft` | черновик |
    | `:active` | действует |
    """

    use Core.Enum,
      name: "Статус",
      values: ~w(draft active)a
  end

  defmodule Kind do
    use Core.Enum,
      name: "Вид",
      values: ~w(rect square cat t u)a
  end

  defmodule Shape do
    defmodule Circle do
      use Core.Struct, fields: [radius: [prim: Weight]]
    end

    defmodule Rect do
      use Core.Struct,
        fields: [
          width: [prim: Weight],
          at: [prim: At],
          kind: [enum: Kind, default: :rect]
        ]
    end

    defmodule Square do
      use Core.Struct,
        fields: [
          side: [prim: Weight],
          day: [prim: Day],
          kind: [enum: Kind, default: :square]
        ]
    end

    use Core.Union,
      variants: [
        {Core.Codec.PluginRedumpTest.Shape.Circle, "circle"},
        {Core.Codec.PluginRedumpTest.Shape.Rect, {"polygon", kind: :rect}},
        {Core.Codec.PluginRedumpTest.Shape.Square, {"polygon", kind: :square}}
      ]
  end

  defmodule Pet do
    defmodule Cat do
      use Core.Struct,
        fields: [
          born: [prim: Day],
          kind: [enum: Kind, default: :cat]
        ]
    end

    defmodule Dog do
      use Core.Struct, fields: [id: [prim: ID]]
    end

    use Core.Union,
      variants: [
        {Core.Codec.PluginRedumpTest.Pet.Cat, [kind: :cat]},
        {Core.Codec.PluginRedumpTest.Pet.Dog, [kind: "dog"]}
      ]
  end

  defmodule Tag do
    use Core.Struct, fields: [id: [prim: ID], at: [prim: At]]
  end

  defmodule Labelled do
    use Core.Struct, fields: [label: [prim: Label], name: [prim: Name]]
  end

  defmodule Item do
    use Core.Struct,
      fields: [
        id: [prim: ID],
        name: [prim: Name, wire: "title"],
        note: [prim: Name, optional: true, default: nil],
        secret: [prim: Sensitive],
        secrets: [list: [prim: Sensitive]],
        status: [enum: Status],
        count: [type: :integer],
        flags: [list: [type: :string]],
        at: [prim: At],
        weights: [list: [prim: Weight]],
        tag: [entity: Tag],
        tags: [list: [entity: Tag]],
        shape: [list: [union: Shape]],
        pet: [union: Pet, optional: true, default: nil]
      ]
  end

  defmodule Ledger do
    use Core.Struct,
      fields: [
        name: [prim: Name],
        codes: [map: [key: [prim: ID], value: [enum: Status]]],
        weights: [map: [key: [prim: ID], value: [prim: Weight]]],
        tags: [map: [key: [type: :string], value: [entity: Tag]]],
        secrets: [map: [key: [type: :string], value: [list: [prim: Sensitive]]]]
      ]
  end

  defmodule Roster do
    use Core.Struct,
      fields: [
        ids: [set: [prim: ID]],
        ats: [set: [prim: At]],
        statuses: [set: [enum: Status]],
        tags: [set: [entity: Tag]],
        secrets: [set: [prim: Sensitive]]
      ]
  end

  defmodule Plugin do
    use Core.Codec.Plugin,
      types: [Tag, Labelled, Core.StructFixture.Contact, Ledger, Roster, Item],
      union: Shape
  end

  defmodule PetPlugin do
    use Core.Codec.Plugin, union: Pet
  end

  defmodule Doc do
    defstruct [:id, :at]
  end

  defmodule Step do
    defmodule Weigh do
      use Core.Struct, fields: [weight: [prim: Weight]]
    end

    defmodule Note do
      defstruct [:at]
    end

    use Core.Union,
      variants: [
        {Core.Codec.PluginRedumpTest.Step.Weigh, "weigh"},
        {Core.Codec.PluginRedumpTest.Step.Note, "note"}
      ]
  end

  defmodule ManualPlugin do
    use Core.Codec.Plugin,
      types: [Doc],
      union: Step

    @impl true
    def dump(%Doc{id: id, at: at}, codec), do: %{"id" => codec.dump(id), "at" => codec.dump(at)}

    @impl true
    def load(Doc, wire, codec) do
      with {:ok, id} <- codec.load(ID, field(wire, :id)),
           {:ok, at} <- codec.load(At, field(wire, :at)),
           do: {:ok, %Doc{id: id, at: at}}
    end

    @impl true
    def dump_variant(%Step.Note{at: at}, codec), do: %{"at" => codec.dump(at)}

    @impl true
    def load_variant(Step.Note, fields, codec) do
      with {:ok, at} <- codec.load(At, field(fields, :at)), do: {:ok, %Step.Note{at: at}}
    end

    @impl true
    def redump_spec(Doc), do: {:map, %{id: {:prim, ID}, at: {:prim, At}}}
    def redump_spec(Step.Note), do: {:map, %{at: {:prim, At}}}
  end

  defmodule Legacy do
    defmodule Mark do
      defstruct [:at]
    end
  end

  defmodule LegacyPlugin do
    use Core.Codec.Plugin,
      types: [Legacy.Mark],
      union: Legacy

    @impl true
    def dump(%Legacy.Mark{at: at}, codec), do: %{"kind" => "mark", "at" => codec.dump(at)}

    @impl true
    def load(mod, wire, codec) when mod in [Legacy, Legacy.Mark] do
      with {:ok, at} <- codec.load(At, field(wire, :at)), do: {:ok, %Legacy.Mark{at: at}}
    end

    @impl true
    def redump_spec(Legacy), do: {:map, %{at: {:prim, At}}}
  end

  defmodule Cell do
    defmodule Dot do
      defstruct [:at]
    end

    use Core.Union, variants: [{Core.Codec.PluginRedumpTest.Cell.Dot, "dot"}]
  end

  defmodule NoSpecPlugin do
    use Core.Codec.Plugin, union: Cell

    @impl true
    def dump_variant(%Cell.Dot{at: at}, codec), do: %{"at" => codec.dump(at)}

    @impl true
    def load_variant(Cell.Dot, fields, codec) do
      with {:ok, at} <- codec.load(At, field(fields, :at)), do: {:ok, %Cell.Dot{at: at}}
    end
  end

  defmodule In do
    use Core.Codec.Facade,
      prim: Core.CodecFixture.Prim.Internal,
      plugins: [
        Core.Codec.PluginRedumpTest.Plugin,
        Core.Codec.PluginRedumpTest.PetPlugin,
        Core.Codec.PluginRedumpTest.ManualPlugin,
        Core.Codec.PluginRedumpTest.LegacyPlugin,
        Core.Codec.PluginRedumpTest.NoSpecPlugin
      ]
  end

  defmodule Out do
    use Core.Codec.Facade,
      prim: Core.CodecFixture.Prim.External,
      plugins: [
        Core.Codec.PluginRedumpTest.Plugin,
        Core.Codec.PluginRedumpTest.PetPlugin,
        Core.Codec.PluginRedumpTest.ManualPlugin,
        Core.Codec.PluginRedumpTest.LegacyPlugin,
        Core.Codec.PluginRedumpTest.NoSpecPlugin
      ]
  end

  @uuid "550e8400-e29b-41d4-a716-446655440000"

  describe "выведенная спека типа по полям" do
    test "состав по видам полей, wire-ключ" do
      assert Plugin.__codec_redump__(Item) ==
               {:map,
                %{
                  id: {:prim, ID},
                  title: {:prim, Name},
                  note: {:prim, Name},
                  secret: :sensitive,
                  secrets: :sensitive,
                  at: {:prim, At},
                  weights: {:list, {:prim, Weight}},
                  tag: {:codec, Tag},
                  tags: {:list, {:codec, Tag}},
                  shape: {:list, {:codec, Shape}},
                  pet: {:codec, Pet}
                }}

      assert Redump.validate!(Plugin.__codec_redump__(Item))
    end

    test "personal-Prim входит в спеку как обычный" do
      assert Plugin.__codec_redump__(Core.StructFixture.Contact) ==
               {:map, %{phone: {:prim, Personal}, phones: {:list, {:prim, Personal}}}}
    end

    test "словарь — {:dict, ключ, значение}: часть без пере-дампа — nil, sensitive-значение снимает поле" do
      assert Plugin.__codec_redump__(Ledger) ==
               {:map,
                %{
                  name: {:prim, Name},
                  codes: {:dict, {:prim, ID}, nil},
                  weights: {:dict, {:prim, ID}, {:prim, Weight}},
                  tags: {:dict, nil, {:codec, Tag}},
                  secrets: :sensitive
                }}

      assert Redump.validate!(Plugin.__codec_redump__(Ledger))
    end

    test "множество — {:set, спека элемента}; элемент без пере-дампа — нет, sensitive — снимает поле" do
      assert Plugin.__codec_redump__(Roster) ==
               {:map,
                %{ids: {:set, {:prim, ID}}, ats: {:set, {:prim, At}}, tags: {:set, {:codec, Tag}}, secrets: :sensitive}}

      assert Redump.validate!(Plugin.__codec_redump__(Roster))
    end

    test "словарь и множество переводятся как дамп внешним профилем" do
      ledger = %Ledger{
        name: Name.new!("Склад"),
        codes: %{ID.new!(@uuid) => :active},
        weights: %{ID.new!(@uuid) => Weight.new!(Decimal.new("10.5"))},
        tags: %{"верх" => %Tag{id: ID.new!(@uuid), at: At.new!(~U[2024-06-02 08:30:00Z])}},
        secrets: %{"к" => [Sensitive.new!("s3cr3t-value")]}
      }

      assert redump(ledger, Ledger) == Map.delete(json_roundtrip(Out.dump(ledger)), "secrets")
      assert redump(ledger, Ledger)["codes"] == %{String.replace(@uuid, "-", "") => "active"}

      # Порядок термов `DateTime` — не хронологический, порядок JSON-кодировки — хронологический.
      ats = [~U[2024-01-02 00:00:00Z], ~U[2023-12-05 00:00:00Z], ~U[2023-12-31 00:00:00Z]]

      roster = %Roster{
        ids: MapSet.new([ID.new!(@uuid)]),
        ats: MapSet.new(ats, &At.new!/1),
        statuses: MapSet.new(~w(draft active)a),
        tags: MapSet.new([%Tag{id: ID.new!(@uuid), at: At.new!(~U[2024-06-02 08:30:00Z])}]),
        secrets: MapSet.new([Sensitive.new!("s3cr3t-value")])
      }

      refute Enum.sort(ats) == Enum.sort(ats, DateTime)

      assert json_roundtrip(In.dump(roster))["ats"] ==
               ~w(2023-12-05T00:00:00Z 2023-12-31T00:00:00Z 2024-01-02T00:00:00Z)

      assert redump(roster, Roster) == Map.delete(json_roundtrip(Out.dump(roster)), "secrets")
    end

    test "Prim с кастомным kind в спеку не входит" do
      assert Plugin.__codec_redump__(Labelled) == {:map, %{name: {:prim, Name}}}
    end

    test "пере-дамп совпадает с дампом внешним профилем; sensitive-поля нет" do
      item = item()
      expected = Map.drop(json_roundtrip(Out.dump(item)), ~w(secret secrets))

      assert redump(item, Item) == expected
      refute Map.has_key?(expected, "secret")
      assert expected["title"] == "Иван"
      assert expected["id"] == String.replace(@uuid, "-", "")
    end

    test "значение с ключами-атомами переводится так же" do
      atom_keyed = %{id: @uuid, title: "Иван", secret: "s3cr3t-value"}

      assert Redump.run(atom_keyed, {:codec, Item}, Out) == %{id: String.replace(@uuid, "-", ""), title: "Иван"}
    end
  end

  describe "выведенная спека варианта и семейства" do
    test "вариант — форма его дампа" do
      assert Plugin.__codec_redump__(Shape.Circle) == {:tagged, %{"circle" => {:map, %{radius: {:prim, Weight}}}}}

      assert Plugin.__codec_redump__(Shape.Rect) ==
               {:tagged, %{"polygon" => {:map, %{width: {:prim, Weight}, at: {:prim, At}}}}}

      assert PetPlugin.__codec_redump__(Pet.Cat) == {:map, %{born: {:prim, Day}}}

      for variant <- [circle(), rect(), cat()] do
        assert redump(variant, variant.__struct__) == json_roundtrip(Out.dump(variant))
      end
    end

    test "семейство: варианты одного тега сливаются, форма без обёртки — одна map" do
      assert Plugin.__codec_redump__(Shape) ==
               {:tagged,
                %{
                  "circle" => {:map, %{radius: {:prim, Weight}}},
                  "polygon" =>
                    {:map, %{width: {:prim, Weight}, at: {:prim, At}, side: {:prim, Weight}, day: {:prim, Day}}}
                }}

      assert PetPlugin.__codec_redump__(Pet) == {:map, %{born: {:prim, Day}, id: {:prim, ID}}}
    end

    test "семейство в каждой форме адреса переводится как дамп внешним профилем" do
      for {family, variant} <- [{Shape, circle()}, {Shape, rect()}, {Shape, square()}, {Pet, cat()}, {Pet, dog()}] do
        assert redump(variant, family) == json_roundtrip(Out.dump(variant))
      end
    end

    test "одноимённый ключ с разной спекой у сливаемых вариантов — CompileError" do
      assert_raise CompileError,
                   ~r/Clash: variants: — wire-ключ "x" с разной спекой redump у вариантов .*Clash.T, .*Clash.U под тегом "t"/,
                   fn ->
                     compile_family(
                       :Clash,
                       [k: [enum: Kind, default: :t], x: [prim: Name]],
                       [k: [enum: Kind, default: :u], x: [prim: Day]],
                       {"t", [k: :t]},
                       {"t", [k: :u]}
                     )
                   end

      assert_raise CompileError, ~r/wire-ключ "x" .*InlineClash.T, .*InlineClash.U в форме без обёртки/, fn ->
        compile_family(
          :InlineClash,
          [k: [enum: Kind, default: :t], x: [prim: Name]],
          [k: [enum: Kind, default: :u], x: [list: [prim: Name]]],
          [k: :t],
          k: :u
        )
      end
    end

    test "одноимённый ключ с одной спекой и без спеки — не конфликт" do
      compile_family(
        :NoClash,
        [k: [enum: Kind, default: :t], x: [prim: Name]],
        [k: [enum: Kind, default: :u], x: [prim: Name]],
        {"t", [k: :t]},
        {"t", [k: :u]}
      )

      compile_family(
        :NoSpecClash,
        [k: [enum: Kind, default: :t], x: [type: :string]],
        [k: [enum: Kind, default: :u], x: [prim: Name]],
        [k: :t],
        k: :u
      )
    end
  end

  describe "ручная спека — колбэк redump_spec/1" do
    test "ручной тип" do
      doc = %Doc{id: ID.new!(@uuid), at: At.new!(~U[2024-06-01 12:00:00Z])}

      assert redump(doc, Doc) == json_roundtrip(Out.dump(doc))
    end

    test "ручной вариант в семействе с variants:" do
      note = %Step.Note{at: At.new!(~U[2024-06-01 12:00:00Z])}
      weigh = %Step.Weigh{weight: Weight.new!(Decimal.new("3.5"))}

      assert ManualPlugin.__codec_redump__(Step.Note) == {:tagged, %{"note" => {:map, %{at: {:prim, At}}}}}

      for {mod, value} <- [{Step.Note, note}, {Step, note}, {Step, weigh}] do
        assert redump(value, mod) == json_roundtrip(Out.dump(value))
      end
    end

    test "семейство без variants:" do
      mark = %Legacy.Mark{at: At.new!(~U[2024-06-01 12:00:00Z])}

      assert redump(mark, Legacy) == json_roundtrip(Out.dump(mark))
    end

    test "клауза колбэка на тип с выведенной спекой — CompileError never match" do
      assert_raise CompileError, ~r/never match — redump_spec\/1 для .*Derived\.T \(строка \d+\).*выводит плагин/, fn ->
        compile_single(:Derived, [a: [prim: Name]], quote(do: def(redump_spec(T), do: {:map, %{}})))
      end

      assert_raise CompileError, ~r/never match — redump_spec\/1 для .*DerivedFamily\.Family/, fn ->
        compile_single(
          :DerivedFamily,
          [a: [prim: Name]],
          quote(do: def(redump_spec(Family), do: {:map, %{}})),
          family: true
        )
      end
    end
  end

  describe "тип без спеки — ArgumentError" do
    test "тип ручного плагина без клаузы колбэка" do
      assert_raise ArgumentError, ~r/Legacy.Mark: у codec-плагина .*LegacyPlugin нет спеки redump/, fn ->
        Redump.run(%{}, {:codec, Legacy.Mark}, Out)
      end
    end

    test "ручной вариант без клаузы — у варианта и у семейства" do
      for mod <- [Cell.Dot, Cell] do
        assert_raise ArgumentError, ~r/Cell.Dot: у codec-плагина .*NoSpecPlugin нет спеки redump/, fn ->
          Redump.run(%{}, {:codec, mod}, Out)
        end
      end
    end

    test "тип без спеки клаузы плагина не получает — отказ бросает фасад" do
      refute Core.Helper.Module.exports?(NoSpecPlugin, :__codec_redump__, 1)
      assert NoSpecPlugin.__codec_redump_missing__() == [{Cell.Dot, Cell.Dot}, {Cell, Cell.Dot}]

      assert LegacyPlugin.__codec_redump_missing__() == [{Legacy.Mark, Legacy.Mark}]
      assert LegacyPlugin.__codec_redump__(Legacy) == {:map, %{at: {:prim, At}}}
    end

    test "фасад без единой спеки — признак для @spec no_return()" do
      refute Core.Codec.Facade.redump?([NoSpecPlugin])
      assert Core.Codec.Facade.redump?([NoSpecPlugin, LegacyPlugin])
    end

    test "модуль без плагина" do
      assert_raise ArgumentError, ~r/Unknown: нет codec-плагина в фасаде .*PluginRedumpTest.Out/, fn ->
        Redump.run(%{}, {:codec, Unknown}, Out)
      end
    end
  end

  defp redump(value, type), do: Redump.run(json_roundtrip(In.dump(value)), {:codec, type}, Out)

  defp json_roundtrip(value), do: Jason.decode!(Jason.encode!(value))

  defp item do
    %Item{
      id: ID.new!(@uuid),
      name: Name.new!("Иван"),
      note: nil,
      secret: Sensitive.new!("s3cr3t-value"),
      secrets: [Sensitive.new!("s3cr3t-value")],
      status: :draft,
      count: 3,
      flags: ["a"],
      at: At.new!(~U[2024-06-01 12:00:00Z]),
      weights: [Weight.new!(Decimal.new("10.5"))],
      tag: %Tag{id: ID.new!(@uuid), at: At.new!(~U[2024-06-02 08:30:00Z])},
      tags: [%Tag{id: ID.new!(@uuid), at: At.new!(~U[2024-06-03 08:30:00Z])}],
      shape: [circle(), rect(), square()],
      pet: cat()
    }
  end

  defp circle, do: %Shape.Circle{radius: Weight.new!(Decimal.new("1.5"))}
  defp rect, do: %Shape.Rect{width: Weight.new!(Decimal.new("2")), at: At.new!(~U[2024-06-01 12:00:00Z])}
  defp square, do: %Shape.Square{side: Weight.new!(Decimal.new("4")), day: Day.new!(~D[2024-06-01])}
  defp cat, do: %Pet.Cat{born: Day.new!(~D[2020-01-01])}
  defp dog, do: %Pet.Dog{id: ID.new!(@uuid)}

  defp compile_family(name, fields_t, fields_u, address_t, address_u) do
    plugin = Module.concat(__MODULE__, name)

    Code.eval_quoted(
      quote do
        defmodule unquote(plugin) do
          defmodule T do
            use Core.Struct, fields: unquote(Macro.escape(fields_t))
          end

          defmodule U do
            use Core.Struct, fields: unquote(Macro.escape(fields_u))
          end

          defmodule Family do
            use Core.Union,
              variants: [
                {unquote(Module.concat(plugin, :T)), unquote(Macro.escape(address_t))},
                {unquote(Module.concat(plugin, :U)), unquote(Macro.escape(address_u))}
              ]
          end

          use Core.Codec.Plugin, union: unquote(Module.concat(plugin, :Family))
        end
      end
    )
  end

  defp compile_single(name, fields, clause, opts \\ []) do
    plugin = Module.concat(__MODULE__, name)

    Code.eval_quoted(
      quote do
        defmodule unquote(plugin) do
          defmodule T do
            use Core.Struct, fields: unquote(Macro.escape(fields))
          end

          if unquote(Keyword.get(opts, :family, false)) do
            defmodule Family do
              use Core.Union,
                variants: [{unquote(Module.concat(plugin, :T)), "t"}]
            end

            use Core.Codec.Plugin, union: unquote(Module.concat(plugin, :Family))
          else
            use Core.Codec.Plugin, types: [unquote(Module.concat(plugin, :T))]
          end

          unquote(clause)
        end
      end
      |> Macro.prewalk(fn
        {:__aliases__, _meta, [leaf]} when leaf in ~w(T Family)a -> Module.concat(plugin, leaf)
        ast -> ast
      end)
    )
  end
end
