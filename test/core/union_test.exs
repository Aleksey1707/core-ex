defmodule Core.UnionTest do
  use ExUnit.Case, async: true

  alias Core.Error
  alias Core.Union
  alias Core.Union.Variant
  alias Core.UnionFixture.Blob
  alias Core.UnionFixture.Canvas
  alias Core.UnionFixture.Cat
  alias Core.UnionFixture.Circle
  alias Core.UnionFixture.Dog
  alias Core.UnionFixture.Drawing
  alias Core.UnionFixture.Email
  alias Core.UnionFixture.Facade
  alias Core.UnionFixture.Name
  alias Core.UnionFixture.Pet
  alias Core.UnionFixture.Phone
  alias Core.UnionFixture.Polygon
  alias Core.UnionFixture.Recipient
  alias Core.UnionFixture.Rect
  alias Core.UnionFixture.Shape
  alias Core.UnionFixture.Square
  alias Core.UnionFixture.Star
  alias Core.UnionFixture.Triangle

  describe "объявление" do
    test "__core_variants__/0 — модуль, адрес как объявлен, место и вид варианта" do
      assert [circle, square] = Shape.__core_variants__()

      assert %Variant{
               module: Circle,
               address: "circle",
               place: {:tagged, "circle", nil},
               kind: :domain
             } = circle

      assert %Variant{module: Square, address: "square", place: {:tagged, "square", nil}, kind: :domain} = square

      assert %Variant{module: Phone, kind: :prim} =
               Enum.find(Recipient.__core_variants__(), &match?(%Variant{module: Phone}, &1))

      assert %Variant{module: Blob, address: "blob", kind: :manual} =
               Enum.find(Drawing.__core_variants__(), &match?(%Variant{module: Blob}, &1))

      assert %Variant{module: Star, address: "star", kind: :domain} =
               Enum.find(Drawing.__core_variants__(), &match?(%Variant{module: Star}, &1))

      assert %Variant{module: Rect, place: {:tagged, "polygon", {:kind, "rect"}}} =
               Enum.find(Polygon.__core_variants__(), &match?(%Variant{module: Rect}, &1))

      assert %Variant{module: Cat, place: {:inline, {:kind, "cat"}}} =
               Enum.find(Pet.__core_variants__(), &match?(%Variant{module: Cat}, &1))
    end

    test "types/0 — wire-теги и значения дискриминатора" do
      assert Shape.types() == MapSet.new(~w(circle square))
      assert Polygon.types() == MapSet.new(["polygon"])
      assert Pet.types() == MapSet.new(~w(cat dog))
      assert Recipient.types() == MapSet.new(~w(phone email))
    end

    test "variant/1 — по struct и по модулю, чужой модуль — :error" do
      assert {:ok, %Variant{module: Circle, kind: :domain}} = Shape.variant(%Circle{radius: 1})
      assert {:ok, %Variant{module: Circle}} = Shape.variant(Circle)
      assert {:ok, %Variant{module: Phone, kind: :prim}} = Recipient.variant(Phone.new!("+79990000000"))
      assert {:ok, %Variant{module: Blob, kind: :manual}} = Drawing.variant(%Blob{points: []})
      assert :error = Shape.variant(Rect)
      assert :error = Shape.variant(%Triangle{sides: [1, 2, 3]})
    end

    test "интроспекция семейства для обходчика — без знания Codec-плагина" do
      assert [%Variant{module: Circle}, %Variant{module: Square}] = Union.variants(Shape)
      assert Union.variants(Rect) == []
      assert Core.Field.union_variants(Shape) == Shape.__core_variants__()
    end

    test "варианты объявляются внутри модуля семейства" do
      Code.eval_quoted(
        quote do
          defmodule Core.UnionTest.Nested do
            defmodule Point do
              defstruct [:x]
            end

            use Core.Union, variants: [{__MODULE__.Point, "point"}]
          end
        end
      )

      union = Core.UnionTest.Nested

      assert [%Variant{module: Core.UnionTest.Nested.Point, address: "point", kind: :manual}] =
               union.__core_variants__()
    end

    test "тип записи семейства — модули вариантов, а не struct()" do
      fields = [
        %Core.Field{
          name: :shape,
          wire: "shape",
          spec: {:union, Shape},
          optional?: false,
          default: :none,
          personal: nil,
          subject: nil
        }
      ]

      assert [shape: type] = Core.Field.write_typespec(fields)
      text = Macro.to_string(type)

      assert text =~ "Core.UnionFixture.Circle.write_t()"
      assert text =~ "Core.UnionFixture.Square.write_t()"
    end
  end

  describe "round-trip через фасад" do
    test "тегированная форма: дамп и загрузка по семейству и по варианту" do
      assert Facade.dump(%Circle{radius: 5}) == %{"type" => "circle", "fields" => %{"radius" => 5}}

      for value <- [%Circle{radius: 5}, %Square{side: 2}] do
        wire = Facade.dump(value)

        assert Facade.load(Shape, wire) == {:ok, value}
        assert Facade.load(value.__struct__, wire) == {:ok, value}
      end
    end

    test "общий тег: дискриминатор в fields, загрузка оставляет поле по умолчанию" do
      assert Facade.dump(%Rect{width: 2, height: 3}) == %{
               "type" => "polygon",
               "fields" => %{"kind" => "rect", "width" => 2, "height" => 3}
             }

      for value <- [%Rect{width: 2, height: 3}, %Triangle{sides: [3, 4, 5]}] do
        wire = Facade.dump(value)

        assert Facade.load(Polygon, wire) == {:ok, value}
        assert Facade.load(value.__struct__, wire) == {:ok, value}
      end
    end

    test "форма без обёртки: дискриминатор среди полей" do
      cat = %Cat{name: Name.new!("Барсик")}

      assert Facade.dump(cat) == %{"kind" => "cat", "name" => "Барсик"}
      assert Facade.load(Pet, Facade.dump(cat)) == {:ok, cat}
      assert Facade.load(Dog, Facade.dump(%Dog{name: Name.new!("Шарик")})) == {:ok, %Dog{name: Name.new!("Шарик")}}
    end

    test "вариант-Prim: fields — дамп Prim, загрузка — load(Prim, fields)" do
      phone = Phone.new!("+79990000000")
      email = Email.new!("a@b.c")

      assert Facade.dump(phone) == %{"type" => "phone", "fields" => "+79990000000"}

      for value <- [phone, email] do
        wire = Facade.dump(value)

        assert Facade.load(Recipient, wire) == {:ok, value}
        assert Facade.load(value.__struct__, wire) == {:ok, value}
      end

      assert {:error, %Error{ns: :prim}} = Facade.load(Recipient, %{"type" => "phone", "fields" => ""})
    end

    test "вариант с ручным Codec: поля колбэком, обёртку пишет плагин" do
      blob = %Blob{points: ~w(a b)}

      assert Facade.dump(blob) == %{"type" => "blob", "fields" => %{"points" => "a,b"}}
      assert Facade.load(Drawing, Facade.dump(blob)) == {:ok, blob}
      assert Facade.load(Blob, Facade.dump(blob)) == {:ok, blob}
    end

    test "поле union: и ошибки разбора" do
      canvas = %Canvas{shape: %Circle{radius: 1}, recipient: nil, drawing: %Blob{points: ["a"]}}

      wire = Facade.dump(canvas)

      assert wire["shape"] == %{"type" => "circle", "fields" => %{"radius" => 1}}
      assert wire["recipient"] == nil
      assert wire["drawing"] == %{"type" => "blob", "fields" => %{"points" => "a"}}

      assert Facade.dump(%Canvas{shape: %Circle{radius: 1}, recipient: nil, drawing: %Star{points: 3}})["drawing"] ==
               %{"type" => "star", "fields" => %{"points" => 3}}

      assert Facade.load(Canvas, wire) == {:ok, canvas}

      assert {:error, %Error{ns: :codec, code: :invalid_value}} =
               Facade.load(Shape, %{"type" => "circle", "fields" => "radius"})

      assert {:error, %Error{ns: :codec, code: :unknown_tag, detail: %{tag: "polygon"}}} =
               Facade.load(Shape, %{"type" => "polygon", "fields" => %{}})
    end
  end

  describe "отказы объявления" do
    test "повтор адреса — CompileError" do
      assert_raise CompileError, ~r/Union: variants: повтор адреса \["x"\] у .*Repeat.T, .*Repeat.U/, fn ->
        compile(:Repeat, quote(do: [{T, [k: :x]}, {U, [k: "x"]}]))
      end

      assert_raise CompileError, ~r/Union: variants: .*повтор адреса \["x"\]/, fn ->
        compile(:TaggedRepeat, quote(do: [{T, {"t", k: :x}}, {U, {"t", k: "x"}}]))
      end
    end

    test "общий тег без дискриминатора — CompileError" do
      assert_raise CompileError, ~r/Union: variants: тег "t" общий у .*NoDisc.T, .*NoDisc.U.*без дискриминатора/, fn ->
        compile(:NoDisc, quote(do: [{T, "t"}, {U, "t"}]))
      end

      assert_raise CompileError, ~r/Union: variants: .*без дискриминатора/, fn ->
        compile(:HalfDisc, quote(do: [{T, "t"}, {U, {"t", k: :u}}]))
      end
    end

    test "две формы адреса в одном семействе — CompileError" do
      assert_raise CompileError, ~r/Union: variants: адреса одной формы/, fn ->
        compile(:Mixed, quote(do: [{T, "t"}, {U, [k: :u]}]))
      end
    end

    test "разные ключи дискриминатора — CompileError" do
      assert_raise CompileError, ~r/Union: variants: .*разные ключи дискриминатора у .*Keys.T, .*Keys.U/, fn ->
        compile(:Keys, quote(do: [{T, {"t", k: :t}}, {U, {"t", j: :u}}]))
      end

      assert_raise CompileError,
                   ~r/Union: variants: .*разные ключи дискриминатора у .*InlineKeys.T, .*InlineKeys.U/,
                   fn ->
                     compile(:InlineKeys, quote(do: [{T, [k: :t]}, {U, [j: :u]}]))
                   end
    end

    test "значение поля дискриминатора по умолчанию не равно адресу — CompileError" do
      assert_raise CompileError,
                   ~r/Union: variants: .*Rect: поле :kind по умолчанию :rect, а дискриминатор — :square/,
                   fn ->
                     Code.eval_quoted(
                       quote do
                         defmodule Core.UnionTest.BadDefault do
                           defmodule Rect do
                             defstruct [:width, kind: :rect]
                           end

                           use Core.Union, variants: [{Core.UnionTest.BadDefault.Rect, {"polygon", kind: :square}}]
                         end
                       end
                     )
                   end
    end

    test "wire-ключ дискриминатора занят другим полем — CompileError" do
      assert_raise CompileError, ~r/Union: variants: .*Clash.Badge: wire-ключ "kind" занят дискриминатором/, fn ->
        Code.eval_quoted(
          quote do
            defmodule Core.UnionTest.Clash do
              defmodule Badge do
                defstruct kind: "badge"

                def __struct_fields__ do
                  [
                    %Core.Codec.Field{
                      name: :j,
                      spec: {:type, :string},
                      optional?: false,
                      wire: "kind",
                      default: :none,
                      subject: nil
                    }
                  ]
                end
              end

              use Core.Union, variants: [{Core.UnionTest.Clash.Badge, [kind: "badge"]}]
            end
          end
        )
      end
    end

    test "вариант-Prim в форме без обёртки — CompileError" do
      assert_raise CompileError, ~r/Union: variants: .*Phone: Prim-вариант — только тегированная форма/, fn ->
        Code.eval_quoted(
          quote do
            defmodule Core.UnionTest.PrimInline do
              use Core.Union, variants: [{Core.UnionFixture.Phone, [kind: :phone]}]
            end
          end
        )
      end
    end

    test "вариант не struct — CompileError" do
      assert_raise CompileError, ~r/Union: variants: .*String: .* не struct/, fn ->
        compile(:NotStruct, quote(do: [{String, "t"}]))
      end
    end

    test "пустой список вариантов и не список — CompileError" do
      assert_raise CompileError, ~r/Union: variants: ожидается непустой список \{Тип, адрес\}/, fn ->
        compile(:Empty, quote(do: []))
      end

      assert_raise CompileError, ~r/Union: variants: ожидается непустой список \{Тип, адрес\}/, fn ->
        compile(:NotList, quote(do: :shape))
      end
    end

    test "вариант не пара {Тип, адрес} — CompileError" do
      assert_raise CompileError, ~r/Union: variants: ожидается \{Тип, адрес\}/, fn ->
        compile(:NotPair, quote(do: [:shape]))
      end
    end
  end

  # ---

  defp compile(name, variants) do
    union = Module.concat(__MODULE__, name)

    quote do
      defmodule unquote(union) do
        defmodule T do
          defstruct [:a]
        end

        defmodule U do
          defstruct [:b]
        end

        use Core.Union, variants: unquote(variants)
      end
    end
    |> Macro.prewalk(fn
      {:__aliases__, _meta, [leaf]} when leaf in ~w(T U)a -> Module.concat(union, leaf)
      ast -> ast
    end)
    |> Code.eval_quoted()
  end
end
