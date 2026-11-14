defmodule Core.View.FieldTest do
  use ExUnit.Case, async: true

  alias Core.Codec.Field
  alias Core.ViewFixture
  alias Core.ViewFixture.AllKinds
  alias Core.ViewFixture.OutCodec

  @uuid "550e8400-e29b-41d4-a716-446655440000"
  @hex "550e8400e29b41d4a716446655440000"
  @at ~U[2024-06-01 12:00:00Z]
  @measured_at ~U[2024-06-01 12:00:00.123456Z]

  describe "вид × проекция" do
    test "каждый вид даёт объявление, тип, new/1 и дамп" do
      types = types()
      base = input()
      shaped = %{base | set: MapSet.new([@uuid]), map: %{@uuid => :new}}
      dumped = dump()
      view = AllKinds.new(Map.to_list(base))
      dumped_view = AllKinds.Codec.dump(view, OutCodec)

      for kind <- Field.kinds(:view) do
        assert Map.has_key?(types, kind), "нет строки таблицы для вида #{kind}"
        assert Map.fetch!(view, kind) == Map.fetch!(shaped, kind), "new/1: #{kind}"
        assert Map.fetch!(dumped_view, kind) == Map.fetch!(dumped, kind), "dump: #{kind}"
      end

      assert Enum.sort(Map.keys(types)) == Enum.sort(Field.kinds(:view))
      assert Map.keys(types) == Map.keys(base)
      assert declared_types() == types
    end
  end

  # ---

  defp types do
    %{
      prim: "String.t()",
      enum: "Core.ViewFixture.Status.t()",
      type: "pos_integer()",
      view: "Core.ViewFixture.Nested.t()",
      form: "mark()",
      list: "[String.t()]",
      set: "MapSet.t(String.t())",
      map: "%{optional(String.t()) => Core.ViewFixture.Status.t()}",
      jsonb: "map()"
    }
  end

  defp input do
    %{
      prim: @uuid,
      enum: :new,
      type: 7,
      view: ViewFixture.Nested.new(id: @uuid, name: "Вложенное"),
      form: %{code: "m1", at: @at},
      list: [@uuid],
      set: [@uuid],
      map: %{@uuid => "new"},
      jsonb: %{"measured_at" => "2024-06-01T12:00:00.123456Z"}
    }
  end

  defp dump do
    %{
      prim: @hex,
      enum: :new,
      type: 7,
      view: %{id: @hex, name: "Вложенное"},
      form: %{code: "m1", at: OutCodec.dump(ViewFixture.CreatedAt.new!(@at))},
      list: [@hex],
      set: [@hex],
      map: %{@hex => :new},
      jsonb: %{"measured_at" => OutCodec.dump(ViewFixture.MeasuredAt.new!(@measured_at))}
    }
  end

  defp declared_types do
    {:ok, types} = Code.Typespec.fetch_types(AllKinds)

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
end
