defmodule Core.Codec.PluginVariantsTest do
  use ExUnit.Case, async: true

  alias Core.Codec.Field
  alias Core.Codec.Redump
  alias Core.Error
  alias Core.Prim

  defmodule Name do
    use Prim.String, name: "Имя", min_len: 1, max_len: 50
  end

  defmodule Shape do
    defmodule Circle do
      defstruct [:radius]
    end

    defmodule Square do
      defstruct [:side]
    end

    defmodule Rect do
      defstruct [:width, :height, kind: :rect]
    end

    defmodule Triangle do
      defstruct [:sides]
    end

    defmodule Blob do
      defstruct [:points]
    end

    defmodule Label do
      defstruct [:name]
    end
  end

  defmodule ShapePlugin do
    require Error

    use Core.Codec.Plugin,
      union: Shape,
      fields: [{Shape.Label, name: [prim: Name]}],
      variants: [
        {Shape.Circle, "circle", radius: [type: :pos_integer]},
        {Shape.Square, "square", side: [type: :pos_integer]},
        {Shape.Rect, {"polygon", kind: :rect}, width: [type: :pos_integer], height: [type: :pos_integer]},
        {Shape.Triangle, {"polygon", kind: :triangle}, sides: [list: [type: :pos_integer]]},
        {Shape.Blob, "blob"}
      ]

    @impl true
    def dump_variant(%Shape.Blob{points: points}, _codec), do: %{"points" => Enum.join(points, ",")}

    @impl true
    def load_variant(Shape.Blob, fields, _codec) when is_map(fields) do
      case field(fields, :points) do
        points when is_binary(points) -> {:ok, %Shape.Blob{points: String.split(points, ",")}}
        _other -> {:error, Error.domain(Shape.Blob, code: :invalid_value, ns: :codec, message: "нет точек")}
      end
    end
  end

  defmodule Pet do
    defmodule Cat do
      defstruct [:name, kind: :cat]
    end

    defmodule Dog do
      defstruct [:name]
    end
  end

  defmodule PetPlugin do
    use Core.Codec.Plugin,
      union: Pet,
      variants: [
        {Pet.Cat, [kind: :cat], name: [prim: Name]},
        {Pet.Dog, [kind: "dog"], name: [prim: Name]}
      ]
  end

  defmodule Drawing do
    defstruct [:shape, :pet, :shapes, :backdrop]
  end

  defmodule Frame do
    defmodule Box do
      defstruct [:shape]
    end
  end

  defmodule DrawingPlugin do
    use Core.Codec.Plugin,
      union: Frame,
      fields: [
        {Drawing,
         shape: [union: Shape],
         pet: [union: Pet, optional: true],
         shapes: [list: [union: Shape]],
         backdrop: [union: Shape, default: %{"type" => "square", "fields" => %{"side" => 1}}]}
      ],
      variants: [{Frame.Box, "box", shape: [union: Shape]}]
  end

  defmodule Facade do
    use Core.Codec.Facade,
      prim: Core.CodecFixture.Prim.Internal,
      plugins: [ShapePlugin, PetPlugin, DrawingPlugin]
  end

  describe "dump" do
    test "тегированная форма, дискриминатор внутри fields — как объявлен" do
      assert Facade.dump(%Shape.Circle{radius: 5}) == %{"type" => "circle", "fields" => %{"radius" => 5}}

      assert Facade.dump(rect()) == %{
               "type" => "polygon",
               "fields" => %{"kind" => :rect, "width" => 2, "height" => 3}
             }
    end

    test "форма без обёртки — дискриминатор среди полей" do
      assert Facade.dump(cat()) == %{"kind" => :cat, "name" => "Барсик"}
      assert Facade.dump(%Pet.Dog{name: Name.new!("Шарик")}) == %{"kind" => "dog", "name" => "Шарик"}
    end

    test "ручной вариант — поля колбэком, обёртку пишет плагин" do
      assert Facade.dump(%Shape.Blob{points: ~w(a b)}) == %{"type" => "blob", "fields" => %{"points" => "a,b"}}
    end
  end

  describe "load" do
    test "round-trip по семейству и по варианту" do
      for value <- [
            %Shape.Circle{radius: 5},
            %Shape.Square{side: 1},
            rect(),
            %Shape.Triangle{sides: [3, 4, 5]},
            %Shape.Blob{points: ~w(a b)},
            cat(),
            %Pet.Dog{name: Name.new!("Шарик")}
          ] do
        family = if is_struct(value, Pet.Cat) or is_struct(value, Pet.Dog), do: Pet, else: Shape

        assert Facade.load(family, Facade.dump(value)) == {:ok, value}
        assert Facade.load(value.__struct__, Facade.dump(value)) == {:ok, value}
      end
    end

    test "wire из jsonb: строковые и атомарные ключи, дискриминатор строкой" do
      assert Facade.load(Shape, %{"type" => "polygon", "fields" => %{"kind" => "rect", "width" => 2, "height" => 3}}) ==
               {:ok, rect()}

      assert Facade.load(Shape, %{type: "polygon", fields: %{kind: "triangle", sides: [1]}}) ==
               {:ok, %Shape.Triangle{sides: [1]}}

      assert Facade.load(Pet, %{"kind" => "cat", "name" => "Барсик"}) == {:ok, cat()}
    end

    test "поле struct дискриминатора восстановлено значением по умолчанию" do
      assert {:ok, %Shape.Rect{kind: :rect}} =
               Facade.load(Shape, %{"type" => "polygon", "fields" => %{"kind" => "rect", "width" => 1, "height" => 1}})
    end

    test "повреждённая форма — :invalid_value" do
      for wire <- [
            "circle",
            nil,
            %{"fields" => %{}},
            %{"type" => 1, "fields" => %{}},
            %{"type" => "circle", "fields" => "radius"},
            %{"type" => "polygon", "fields" => %{"width" => 1}}
          ] do
        assert {:error, %Error{ns: :codec, code: :invalid_value}} = Facade.load(Shape, wire)
      end

      assert {:error, %Error{ns: :codec, code: :invalid_value}} = Facade.load(Pet, %{"name" => "Барсик"})
      assert {:error, %Error{ns: :codec, code: :invalid_value}} = Facade.load(Pet, [])
    end

    test "адрес вне семейства — :unknown_tag с тегом и дискриминатором" do
      assert {:error, %Error{ns: :codec, code: :unknown_tag, detail: %{tag: "hexagon", discriminator: nil}}} =
               Facade.load(Shape, %{"type" => "hexagon", "fields" => %{}})

      assert {:error, %Error{code: :unknown_tag, detail: %{tag: "polygon", discriminator: "oval"}}} =
               Facade.load(Shape, %{"type" => "polygon", "fields" => %{"kind" => "oval"}})

      assert {:error, %Error{code: :unknown_tag, detail: %{tag: nil, discriminator: "cow"}}} =
               Facade.load(Pet, %{"kind" => "cow", "name" => "Зорька"})
    end

    test "load варианта с адресом другого варианта — :unknown_tag" do
      assert {:error, %Error{code: :unknown_tag}} =
               Facade.load(Shape.Circle, %{"type" => "square", "fields" => %{"side" => 1}})

      assert {:error, %Error{code: :unknown_tag, detail: %{tag: "circle", discriminator: "rect"}}} =
               Facade.load(Shape.Rect, %{"type" => "circle", "fields" => %{"kind" => "rect"}})

      assert {:error, %Error{code: :unknown_tag}} =
               Facade.load(Shape.Rect, %{"type" => "polygon", "fields" => %{"kind" => "triangle", "sides" => []}})

      assert {:error, %Error{code: :unknown_tag}} = Facade.load(Pet.Cat, %{"kind" => "dog", "name" => "Шарик"})
    end

    test "ошибка поля и ручного варианта — итог" do
      assert {:error, %Error{ns: :prim}} = Facade.load(Pet, %{"kind" => "cat", "name" => ""})

      assert {:error, %Error{code: :invalid_value, message: "нет точек"}} =
               Facade.load(Shape, %{"type" => "blob", "fields" => %{}})
    end
  end

  describe "поле union:" do
    test "dump — вариант в форме своего адреса" do
      assert Facade.dump(drawing()) == %{
               "shape" => %{"type" => "circle", "fields" => %{"radius" => 5}},
               "pet" => %{"kind" => :cat, "name" => "Барсик"},
               "shapes" => [
                 %{"type" => "square", "fields" => %{"side" => 1}},
                 %{"type" => "polygon", "fields" => %{"kind" => :rect, "width" => 2, "height" => 3}}
               ],
               "backdrop" => %{"type" => "blob", "fields" => %{"points" => "a,b"}}
             }
    end

    test "round-trip: поле, optional: nil, элементы list:, вложенное семейство варианта" do
      for value <- [drawing(), %{drawing() | pet: nil, shapes: []}] do
        assert Facade.load(Drawing, Facade.dump(value)) == {:ok, value}
      end

      box = %Frame.Box{shape: rect()}

      assert Facade.dump(box) == %{
               "type" => "box",
               "fields" => %{
                 "shape" => %{"type" => "polygon", "fields" => %{"kind" => :rect, "width" => 2, "height" => 3}}
               }
             }

      assert Facade.load(Frame, Facade.dump(box)) == {:ok, box}
    end

    test "optional: отсутствующий ключ — nil; default: — при отсутствии ключа" do
      wire = Map.drop(Facade.dump(drawing()), ~w(pet backdrop))

      assert {:ok, %Drawing{pet: nil, backdrop: %Shape.Square{side: 1}}} = Facade.load(Drawing, wire)
    end

    test "ошибка загрузки семейства — ошибка поля" do
      wire = Facade.dump(drawing())

      assert {:error, %Error{ns: :codec, code: :invalid_value}} =
               Facade.load(Drawing, %{wire | "shape" => "circle"})

      assert {:error, %Error{ns: :codec, code: :unknown_tag, detail: %{tag: "hexagon"}}} =
               Facade.load(Drawing, %{wire | "shapes" => [%{"type" => "hexagon", "fields" => %{}}]})
    end

    test "не struct в поле union: — FunctionClauseError" do
      assert_raise FunctionClauseError, fn -> DrawingPlugin.dump(%{drawing() | shape: %{radius: 5}}, Facade) end
      assert_raise FunctionClauseError, fn -> DrawingPlugin.dump(%{drawing() | pet: :cat}, Facade) end
    end
  end

  describe "интроспекция" do
    test "type/1 и types/0 — по всем формам адреса" do
      assert ShapePlugin.type(rect()) == "polygon"
      assert ShapePlugin.type(Shape.Blob) == "blob"
      assert ShapePlugin.types() == MapSet.new(~w(circle square polygon blob))

      assert PetPlugin.type(Pet.Cat) == "cat"
      assert PetPlugin.types() == MapSet.new(~w(cat dog))
    end

    test "__codec_variants__/0 — адрес и спека, у ручного — :manual" do
      variants = ShapePlugin.__codec_variants__()

      assert {Shape.Rect, {"polygon", [kind: :rect]},
              [
                %Field{
                  name: :width,
                  spec: {:type, :pos_integer}
                }
                | _
              ]} =
               List.keyfind(variants, Shape.Rect, 0)

      assert {Shape.Blob, "blob", :manual} = List.keyfind(variants, Shape.Blob, 0)
      assert length(variants) == 5
    end

    test "поле union: в спеке — {:union, Family}" do
      assert [
               {Frame.Box, "box",
                [
                  %Field{
                    name: :shape,
                    spec: {:union, Shape}
                  }
                ]}
             ] =
               DrawingPlugin.__codec_variants__()
    end

    test "типы плагина — fields: и variants:, без types:" do
      assert ShapePlugin.__codec_types__() |> Enum.sort() ==
               Enum.sort([Shape.Label, Shape.Circle, Shape.Square, Shape.Rect, Shape.Triangle, Shape.Blob])
    end

    test "Redump {:tagged, _} читает форму плагина" do
      wire = Facade.dump(%Shape.Circle{radius: 5})

      assert Redump.run(wire, {:tagged, %{"circle" => {:map, %{}}}}, Facade) == wire
    end
  end

  describe "сборка" do
    test "variants: без union: — CompileError" do
      assert_raise CompileError, ~r/variants: требует union:/, fn ->
        compile(:NoUnion, quote(do: [{T, "t", a: [type: :string]}]), union: false)
      end
    end

    test "тип в двух опциях — CompileError" do
      assert_raise CompileError, ~r/типы объявлены в нескольких опциях: \[.*Twice.T\]/, fn ->
        compile(:Twice, quote(do: [{T, "t", a: [type: :string]}]), types: true)
      end
    end

    test "плагин без типов — CompileError" do
      assert_raise CompileError, ~r/нет типов/, fn ->
        Code.eval_quoted(
          quote do
            defmodule Core.Codec.PluginVariantsTest.Empty do
              use Core.Codec.Plugin, loadable: false
            end
          end
        )
      end
    end

    test "две формы адреса в одном плагине — CompileError" do
      assert_raise CompileError, ~r/адреса одной формы/, fn ->
        compile(:Mixed, quote(do: [{T, "t", a: [type: :string]}, {U, [k: :u], b: [type: :string]}]))
      end
    end

    test "общий тег без дискриминатора — CompileError" do
      assert_raise CompileError, ~r/variants: тег "t" общий у .*NoDisc.T, .*NoDisc.U.*без дискриминатора/, fn ->
        compile(:NoDisc, quote(do: [{T, "t", a: [type: :string]}, {U, "t", b: [type: :string]}]))
      end
    end

    test "общий тег вперемешку с дискриминатором — CompileError" do
      assert_raise CompileError, ~r/без дискриминатора/, fn ->
        compile(:HalfDisc, quote(do: [{T, "t", a: [type: :string]}, {U, {"t", k: :u}, b: [type: :string]}]))
      end
    end

    test "разные ключи дискриминатора у одного тега и у формы без обёртки — CompileError" do
      assert_raise CompileError, ~r/разные ключи дискриминатора у .*Keys.T, .*Keys.U/, fn ->
        compile(:Keys, quote(do: [{T, {"t", k: :t}, a: [type: :string]}, {U, {"t", j: :u}, b: [type: :string]}]))
      end

      assert_raise CompileError, ~r/разные ключи дискриминатора у .*InlineKeys.T, .*InlineKeys.U/, fn ->
        compile(:InlineKeys, quote(do: [{T, [k: :t], a: [type: :string]}, {U, [j: :u], b: [type: :string]}]))
      end
    end

    test "повтор адреса — CompileError" do
      assert_raise CompileError, ~r/повтор адреса \["x"\] у .*Repeat.T, .*Repeat.U/, fn ->
        compile(:Repeat, quote(do: [{T, [k: :x], a: [type: :string]}, {U, [k: "x"], b: [type: :string]}]))
      end

      assert_raise CompileError, ~r/повтор адреса \["x"\]/, fn ->
        compile(
          :TaggedRepeat,
          quote(do: [{T, {"t", k: :x}, a: [type: :string]}, {U, {"t", k: :x}, b: [type: :string]}])
        )
      end
    end

    test "дискриминатор не одна пара ключ: значение — CompileError" do
      assert_raise CompileError, ~r/variants, вариант .*: дискриминатор — одна пара ключ: значение/, fn ->
        compile(:Pair, quote(do: [{T, {"t", k: :t, j: :t}, a: [type: :string]}]))
      end
    end

    test "wire-ключ поля равен ключу дискриминатора — CompileError" do
      assert_raise CompileError, ~r/wire-ключ "k" занят дискриминатором/, fn ->
        compile(:Clash, quote(do: [{T, [k: :t], a: [type: :string, wire: "k"]}]))
      end
    end

    test "значение по умолчанию поля дискриминатора не равно адресу — CompileError" do
      assert_raise CompileError, ~r/поле :kind по умолчанию :rect, а дискриминатор — :square/, fn ->
        Code.eval_quoted(
          quote do
            defmodule Core.Codec.PluginVariantsTest.BadDefault do
              use Core.Codec.Plugin,
                union: Core.Codec.PluginVariantsTest.Shape,
                variants: [
                  {Core.Codec.PluginVariantsTest.Shape.Rect, {"polygon", kind: :square},
                   width: [type: :pos_integer], height: [type: :pos_integer]}
                ]
            end
          end
        )
      end
    end

    test "спека расходится со struct без поля дискриминатора — CompileError" do
      assert_raise CompileError, ~r/поля struct без спеки \[:a\]/, fn ->
        compile(:Spec, quote(do: [{T, "t", b: [type: :string]}]))
      end
    end

    test "ручной вариант без колбэков — CompileError" do
      assert_raise CompileError, ~r/требуется dump_variant\/2 для \[.*NoCallback.T\]/, fn ->
        compile(:NoCallback, quote(do: [{T, "t"}]))
      end

      assert_raise CompileError, ~r/требуется load_variant\/3 для \[.*NoLoadCallback.T\]/, fn ->
        compile(:NoLoadCallback, quote(do: [{T, "t"}]), clauses: [quote(do: def(dump_variant(%T{}, _codec), do: %{}))])
      end
    end

    test "ручная клауза dump/2 или load/3 на вариант или семейство — CompileError never match" do
      assert_raise CompileError, ~r/never match — dump\/2 для .*DeadDump.T/, fn ->
        compile(:DeadDump, quote(do: [{T, "t", a: [type: :string]}]),
          clauses: [quote(do: def(dump(%T{} = t, _codec), do: t.a))]
        )
      end

      assert_raise CompileError, ~r/never match — load\/3 для .*DeadVariantLoad.T/, fn ->
        compile(:DeadVariantLoad, quote(do: [{T, "t", a: [type: :string]}]),
          clauses: [quote(do: def(load(T, _wire, _codec), do: {:error, :none}))]
        )
      end

      assert_raise CompileError, ~r/never match — load\/3 для .*DeadLoad.Family/, fn ->
        compile(:DeadLoad, quote(do: [{T, "t", a: [type: :string]}]),
          clauses: [quote(do: def(load(Family, _wire, _codec), do: {:error, :none}))]
        )
      end
    end

    test "@spec у dump/2 плагина с variants: — CompileError" do
      assert_raise CompileError, ~r/@spec dump\/2/, fn ->
        compile(:Spec2, quote(do: [{T, "t", a: [type: :string]}]),
          clauses: [quote(do: @spec(dump(struct(), module()) :: map())), quote(do: def(dump(%U{}, _codec), do: %{}))],
          types: :u
        )
      end
    end
  end

  # ---

  defp rect, do: %Shape.Rect{width: 2, height: 3}

  defp cat, do: %Pet.Cat{name: Name.new!("Барсик")}

  defp drawing do
    %Drawing{
      shape: %Shape.Circle{radius: 5},
      pet: cat(),
      shapes: [%Shape.Square{side: 1}, rect()],
      backdrop: %Shape.Blob{points: ~w(a b)}
    }
  end

  defp compile(name, variants, opts \\ []) do
    plugin = Module.concat(__MODULE__, name)

    types =
      case Keyword.get(opts, :types) do
        true -> [quote(do: T)]
        :u -> [quote(do: U)]
        nil -> []
      end

    union = if Keyword.get(opts, :union, true), do: quote(do: Family)
    clauses = Keyword.get(opts, :clauses, [])

    quote do
      defmodule unquote(plugin) do
        defmodule T do
          defstruct [:a]
        end

        defmodule U do
          defstruct [:b]
        end

        use Core.Codec.Plugin,
          types: unquote(types),
          union: unquote(union),
          variants: unquote(variants)

        unquote_splicing(clauses)
      end
    end
    |> Macro.prewalk(fn
      {:__aliases__, _meta, [leaf]} when leaf in ~w(T U Family)a -> Module.concat(plugin, leaf)
      ast -> ast
    end)
    |> Code.eval_quoted()
  end
end
