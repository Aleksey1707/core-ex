defmodule Core.Codec.PluginVariantsTest do
  use ExUnit.Case, async: true

  alias Core.Codec.Redump
  alias Core.Error
  alias Core.Prim

  defmodule Name do
    use Prim.String,
      name: "Имя",
      min_len: 1,
      max_len: 50
  end

  defmodule Kind do
    use Core.Enum,
      name: "Вид",
      values: ~w(rect cat)a
  end

  defmodule Shape do
    defmodule Circle do
      use Core.Struct, fields: [radius: [type: :pos_integer]]
    end

    defmodule Square do
      use Core.Struct, fields: [side: [type: :pos_integer]]
    end

    defmodule Rect do
      use Core.Struct,
        fields: [
          width: [type: :pos_integer],
          height: [type: :pos_integer],
          kind: [enum: Kind, default: :rect]
        ]
    end

    defmodule Triangle do
      use Core.Struct, fields: [sides: [list: [type: :pos_integer]]]
    end

    defmodule Blob do
      defstruct [:points]
    end

    defmodule Label do
      use Core.Struct, fields: [name: [prim: Name]]
    end

    use Core.Union,
      variants: [
        {Core.Codec.PluginVariantsTest.Shape.Circle, "circle"},
        {Core.Codec.PluginVariantsTest.Shape.Square, "square"},
        {Core.Codec.PluginVariantsTest.Shape.Rect, {"polygon", kind: :rect}},
        {Core.Codec.PluginVariantsTest.Shape.Triangle, {"polygon", kind: :triangle}},
        {Core.Codec.PluginVariantsTest.Shape.Blob, "blob"}
      ]
  end

  defmodule ShapePlugin do
    require Error

    use Core.Codec.Plugin,
      types: [Shape.Label],
      union: Shape

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
      use Core.Struct,
        fields: [
          name: [prim: Name],
          kind: [enum: Kind, default: :cat]
        ]
    end

    defmodule Dog do
      use Core.Struct, fields: [name: [prim: Name]]
    end

    use Core.Union,
      variants: [
        {Core.Codec.PluginVariantsTest.Pet.Cat, [kind: :cat]},
        {Core.Codec.PluginVariantsTest.Pet.Dog, [kind: "dog"]}
      ]
  end

  defmodule PetPlugin do
    use Core.Codec.Plugin, union: Pet
  end

  defmodule Drawing do
    use Core.Struct,
      fields: [
        shape: [union: Shape],
        pet: [union: Pet, optional: true, default: nil],
        shapes: [list: [union: Shape]],
        backdrop: [union: Shape, default: %Shape.Square{side: 1}]
      ]
  end

  defmodule Frame do
    defmodule Box do
      use Core.Struct, fields: [shape: [union: Shape]]
    end

    use Core.Union, variants: [{Core.Codec.PluginVariantsTest.Frame.Box, "box"}]
  end

  defmodule DrawingPlugin do
    use Core.Codec.Plugin,
      types: [Drawing],
      union: Frame
  end

  defmodule Mood do
    defmodule Calm do
      use Core.Struct, fields: [level: [type: :pos_integer]]
    end

    defmodule Angry do
      use Core.Struct, fields: [level: [type: :pos_integer]]
    end

    @tag_by_mod %{
      Core.Codec.PluginVariantsTest.Mood.Calm => "calm",
      Core.Codec.PluginVariantsTest.Mood.Angry => "angry"
    }

    use Core.Union, variants: Enum.map(@tag_by_mod, fn {mod, tag} -> {mod, tag} end)
  end

  defmodule MoodPlugin do
    use Core.Codec.Plugin, union: Mood
  end

  defmodule Facade do
    use Core.Codec.Facade,
      prim: Core.CodecFixture.Prim.Internal,
      plugins: [ShapePlugin, PetPlugin, DrawingPlugin, MoodPlugin]
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

    test "variants: выражением — варианты из реестра модуля" do
      assert Facade.dump(%Mood.Calm{level: 1}) == %{"type" => "calm", "fields" => %{"level" => 1}}
      assert Facade.load(Mood, Facade.dump(%Mood.Angry{level: 2})) == {:ok, %Mood.Angry{level: 2}}
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

      assert {:error,
              %Error{
                detail: %{field: :shapes, index: 0},
                parent: %Error{ns: :codec, code: :unknown_tag, detail: %{tag: "hexagon"}}
              }} = Facade.load(Drawing, %{wire | "shapes" => [%{"type" => "hexagon", "fields" => %{}}]})
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

    test "Core.Union.variants/1 — адрес, вид и IR декларативного варианта" do
      variants = Core.Union.variants(Shape)

      assert %{module: Shape.Rect, address: {"polygon", [kind: :rect]}, kind: :domain} =
               Enum.find(variants, &(&1.module == Shape.Rect))

      assert %{module: Shape.Blob, address: "blob", kind: :manual} =
               Enum.find(variants, &(&1.module == Shape.Blob))

      assert length(variants) == 5
    end

    test "поле union: в IR нагрузки — {:union, Family}" do
      assert [
               %Core.Field{
                 name: :shape,
                 spec: {:union, Shape}
               }
             ] = Core.Field.introspect(Frame.Box)
    end

    test "типы плагина — types: и варианты семейства" do
      assert ShapePlugin.__codec_types__() |> Enum.sort() ==
               Enum.sort([Shape.Label, Shape.Circle, Shape.Square, Shape.Rect, Shape.Triangle, Shape.Blob])
    end

    test "Redump {:tagged, _} читает форму плагина" do
      wire = Facade.dump(%Shape.Circle{radius: 5})

      assert Redump.run(wire, {:tagged, %{"circle" => {:map, %{}}}}, Facade) == wire
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
end
