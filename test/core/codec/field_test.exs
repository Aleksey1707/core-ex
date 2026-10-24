defmodule Core.Codec.FieldTest do
  use ExUnit.Case, async: true

  alias Core.Codec.Field
  alias Core.Prim

  defmodule Name do
    use Prim.String, name: "Имя", min_len: 1, max_len: 50
  end

  defmodule Tag do
    defstruct [:name]
  end

  defmodule Status do
    use Core.Enum,
      name: "Статус",
      values: ~w(new done)a
  end

  @where "W"

  describe "форма поля" do
    test "нормализованное поле — struct с именованными ключами" do
      assert [
               %Field{name: :a, spec: {:prim, Name}, optional?: false, wire: "a", default: :none, subject: nil},
               %Field{name: :b, spec: {:list, {:enum, Status}}, optional?: true, wire: "bee", default: :none},
               %Field{name: :c, spec: {:entity, Tag}, default: {:default, %{"name" => "x"}}}
             ] =
               Field.normalize!(
                 [
                   a: [prim: Name],
                   b: [list: [enum: Status], optional: true, wire: "bee"],
                   c: [entity: Tag, default: %{"name" => "x"}]
                 ],
                 :plugin,
                 @where
               )
    end

    test "subject: в режиме нагрузки ложится в поле" do
      assert [%Field{name: :a, subject: :aggregate_id}] =
               Field.normalize!([a: [prim: Name, subject: :aggregate_id]], :payload, @where)
    end

    test "value_spec — спека значения по модулю типа" do
      assert Field.value_spec(Name, @where) == {:prim, Name}
      assert Field.value_spec(Status, @where) == {:enum, Status}
      assert Field.value_spec(Tag, @where) == {:entity, Tag}
    end

    test "subjects — поля с subject: в порядке объявления" do
      fields =
        Field.normalize!(
          [a: [prim: Name, subject: :b], b: [prim: Name], c: [prim: Name, subject: :b]],
          :payload,
          @where
        )

      assert Field.subjects(fields) == [a: :b, c: :b]
    end
  end

  describe "спека плагина" do
    test "пары {Тип, спека} — поля типа" do
      assert [{Tag, [%Field{name: :name, spec: {:prim, Name}}]}] = Field.fields!(P, [{Tag, name: [prim: Name]}], true)
    end

    test "тип объявлен дважды" do
      assert_raise CompileError, ~r/Codec.Plugin P: fields: повторяются \[Core.Codec.FieldTest.Tag\]/, fn ->
        Field.fields!(P, [{Tag, name: [prim: Name]}, {Tag, name: [prim: Name]}], true)
      end
    end

    test "не пара {Тип, спека}" do
      assert_raise CompileError, ~r/Codec.Plugin P: fields: ожидается пара \{Тип, спека\}, задано :x/, fn ->
        Field.fields!(P, [:x], true)
      end
    end

    test "спека сверяется с полями struct" do
      assert_raise CompileError,
                   ~r/W: спека расходится со struct — поля struct без спеки \[:name\], поля спеки без struct \[:title\]/,
                   fn -> Field.variant_fields!(Tag, [title: [prim: Name]], [], @where) end
    end
  end

  describe "kind-ключ" do
    test "ровно один" do
      assert_raise CompileError, ~r/W, поле a: нужен ровно один из prim:\/enum:\/entity:\/union:\/list:\/type:/, fn ->
        Field.normalize!([a: [prim: Name, enum: Status]], :plugin, @where)
      end
    end

    test "неизвестный ключ" do
      assert_raise CompileError, ~r/W, поле a: неизвестные ключи \[:default_value\]/, fn ->
        Field.normalize!([a: [prim: Name, default_value: 1]], :plugin, @where)
      end
    end

    test "неизвестный type:" do
      assert_raise CompileError, ~r/W, поле a: неизвестный type: :atom/, fn ->
        Field.normalize!([a: [type: :atom]], :plugin, @where)
      end
    end
  end

  describe "optional: и list:" do
    test "optional: — boolean" do
      assert_raise CompileError, ~r/W, поле a: optional: boolean, задано :yes/, fn ->
        Field.normalize!([a: [prim: Name, optional: :yes]], :plugin, @where)
      end
    end

    test "optional: не внутри list:" do
      assert_raise CompileError, ~r/W, поле a: optional: задаётся у самого поля, не в list:/, fn ->
        Field.normalize!([a: [list: [prim: Name, optional: true]]], :plugin, @where)
      end
    end

    test "list: — keyword-спека элемента без лишних ключей" do
      assert_raise CompileError, ~r/W, поле a: list: неизвестные ключи \[:wire\]/, fn ->
        Field.normalize!([a: [list: [prim: Name, wire: "x"]]], :plugin, @where)
      end
    end
  end

  describe "wire:" do
    test "непустая строка" do
      assert_raise CompileError, ~r/W, поле a: wire: непустая строка, задано ""/, fn ->
        Field.normalize!([a: [prim: Name, wire: ""]], :plugin, @where)
      end
    end

    test "в нагрузке не начинается с $" do
      assert_raise CompileError, ~r/W, поле a: wire-ключ "\$pd" начинается с \$/, fn ->
        Field.normalize!([a: [prim: Name, wire: "$pd"]], :payload, @where)
      end
    end
  end

  describe "уникальность" do
    test "имён полей" do
      assert_raise CompileError, ~r/W: повторяются \[:a\]/, fn ->
        Field.normalize!([a: [prim: Name], a: [prim: Name]], :plugin, @where)
      end
    end

    test "wire-ключей" do
      assert_raise CompileError, ~r/W, wire-ключи: повторяются \["b"\]/, fn ->
        Field.normalize!([a: [prim: Name, wire: "b"], b: [prim: Name]], :plugin, @where)
      end
    end
  end

  describe "default: по режиму" do
    test "плагин проверяет default: у enum:" do
      assert_raise CompileError, ~r/W, поле a: default: "nwe" не загружается .*Status/, fn ->
        Field.normalize!([a: [enum: Status, default: "nwe"]], :plugin, @where)
      end
    end

    test "default: и optional: true" do
      assert_raise CompileError, ~r/W, поле a: default: и optional: true/, fn ->
        Field.normalize!([a: [prim: Name, default: "x", optional: true]], :plugin, @where)
      end
    end

    test "плагин без загрузки default: не принимает" do
      assert_raise CompileError, ~r/W, поле a: default: при loadable: false/, fn ->
        Field.normalize!([a: [prim: Name, default: "x"]], :dump_only, @where)
      end
    end

    test "нагрузка default: не принимает" do
      assert_raise CompileError, ~r/W: default: у нагрузки события нет \(поля \[:a\]\)/, fn ->
        Field.normalize!([a: [prim: Name, default: "x"]], :payload, @where)
      end
    end
  end

  describe "subject: по режиму" do
    test "плагин subject: не принимает" do
      assert_raise CompileError, ~r/W, поле a: неизвестные ключи \[:subject\]/, fn ->
        Field.normalize!([a: [prim: Name, subject: :aggregate_id]], :plugin, @where)
      end
    end

    test "подписи subject: не принимают" do
      assert_raise CompileError, ~r/W, поле a: неизвестные ключи \[:subject\]/, fn ->
        Field.normalize!([a: [prim: Name, subject: :aggregate_id]], :labels, @where)
      end
    end

    test "в нагрузке subject: — атом" do
      assert_raise CompileError, ~r/W, поле a: subject: атом .*задано "b"/, fn ->
        Field.normalize!([a: [prim: Name, subject: "b"]], :payload, @where)
      end
    end
  end
end
