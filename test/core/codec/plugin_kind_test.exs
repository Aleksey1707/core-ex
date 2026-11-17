defmodule Core.Codec.PluginKindTest do
  use ExUnit.Case, async: true

  alias Core.Codec.Field
  alias Core.DerivedFixture

  defmodule Name do
    use Core.Prim.String,
      name: "Имя",
      min_len: 1,
      max_len: 50
  end

  defmodule Status do
    use Core.Enum,
      name: "Статус",
      values: ~w(new done)a
  end

  defmodule Item do
    use Core.Struct, fields: [name: [prim: Core.Codec.PluginKindTest.Name]]
  end

  defmodule Item.Codec do
    use Core.Codec.Plugin, types: [Core.Codec.PluginKindTest.Item]
  end

  defmodule AllKinds do
    use Core.Struct,
      fields: [
        prim: [prim: Core.Codec.PluginKindTest.Name],
        enum: [enum: Core.Codec.PluginKindTest.Status],
        entity: [entity: Core.Codec.PluginKindTest.Item],
        union: [union: Core.DerivedFixture.Mark],
        list: [list: [prim: Core.Codec.PluginKindTest.Name]],
        set: [set: [prim: Core.Codec.PluginKindTest.Name]],
        map: [map: [key: [prim: Core.Codec.PluginKindTest.Name], value: [type: :integer]]],
        type: [type: :pos_integer]
      ]
  end

  defmodule Plugin do
    use Core.Codec.Plugin, types: [Core.Codec.PluginKindTest.AllKinds]
  end

  defmodule Facade do
    use Core.Codec.Facade,
      prim: Core.CodecFixture.Prim.Internal,
      plugins: [
        Core.Codec.PluginKindTest.Plugin,
        Core.Codec.PluginKindTest.Item.Codec,
        Core.DerivedFixture.Mark.Codec
      ]
  end

  # Значение и wire каждого вида: вид — строка, как ключ дампа по умолчанию.
  setup do
    value = %AllKinds{
      prim: Name.new!("а"),
      enum: :done,
      entity: %Item{name: Name.new!("п")},
      union: %DerivedFixture.Mark.Star{size: 2},
      list: [Name.new!("б")],
      set: MapSet.new([Name.new!("в")]),
      map: %{Name.new!("к") => 1},
      type: 5
    }

    %{value: value}
  end

  test "вид × операция: каждый вид проходит dump/load через фасад", %{value: value} do
    wire = Facade.dump(value)

    assert wire == %{
             "prim" => "а",
             "enum" => :done,
             "entity" => %{"name" => "п"},
             "union" => %{"type" => "star", "fields" => %{"size" => 2}},
             "list" => ["б"],
             "set" => ["в"],
             "map" => %{"к" => 1},
             "type" => 5
           }

    for kind <- Field.kinds(:plugin) do
      assert Map.has_key?(wire, Atom.to_string(kind)), "нет wire для вида #{kind}"
    end

    assert Facade.load(AllKinds, wire) == {:ok, value}
    assert Facade.load(AllKinds, Jason.decode!(Jason.encode!(wire))) == {:ok, value}
  end

  test "вид × операция: голова dump/2 закрывает вид каждого поля", %{value: value} do
    for {kind, bad} <- bad_values() do
      assert_raise FunctionClauseError, fn -> Facade.dump(Map.put(value, kind, bad)) end
    end
  end

  # ---

  defp bad_values do
    %{
      prim: "а",
      enum: "done",
      entity: %{},
      union: %{},
      list: nil,
      set: [],
      map: [],
      type: -1
    }
  end
end
