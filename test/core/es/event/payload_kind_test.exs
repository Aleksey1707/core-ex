defmodule Core.Es.Event.PayloadKindTest do
  use ExUnit.Case, async: true

  alias Core.Codec.Field
  alias Core.DerivedFixture
  alias Core.EventFixture
  alias Core.Version

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
    defstruct [:name]
  end

  defmodule Item.Codec do
    use Core.Codec.Plugin,
      fields: [{Core.Es.Event.PayloadKindTest.Item, name: [prim: Core.Es.Event.PayloadKindTest.Name]}]
  end

  defmodule Kinds do
    use Core.Es.Event.Payload,
      fields: [
        prim: [prim: Core.Es.Event.PayloadKindTest.Name],
        enum: [enum: Core.Es.Event.PayloadKindTest.Status],
        entity: [entity: Core.Es.Event.PayloadKindTest.Item],
        union: [union: Core.DerivedFixture.Mark],
        list: [list: [prim: Core.Es.Event.PayloadKindTest.Name]],
        set: [set: [prim: Core.Es.Event.PayloadKindTest.Name]],
        map: [map: [key: [prim: Core.Es.Event.PayloadKindTest.Name], value: [type: :integer]]],
        type: [type: :non_neg_integer]
      ]
  end

  defmodule Family do
    use Core.Es.Event.Family,
      aggregate: Core.EventFixture,
      aggregate_id: Core.EventFixture.AggID,
      by: Core.EventFixture.ActorID,
      codec: Core.Es.Event.PayloadKindTest.Codec

    @type t :: struct()
  end

  defmodule Event do
    use Core.Es.Event,
      family: Core.Es.Event.PayloadKindTest.Family,
      payload: Core.Es.Event.PayloadKindTest.Kinds
  end

  defmodule Codec do
    use Core.Es.Event.Codec,
      family: Core.Es.Event.PayloadKindTest.Family,
      type: "payload_kinds",
      tags: %{Core.Es.Event.PayloadKindTest.Event => "payload_kinds.event"}
  end

  defmodule Facade do
    use Core.Codec.Facade,
      prim: Core.CodecFixture.Prim.Internal,
      plugins: [
        Core.Es.Event.PayloadKindTest.Codec,
        Core.Es.Event.PayloadKindTest.Item.Codec,
        Core.DerivedFixture.Mark.Codec
      ]
  end

  @at ~U[2026-09-14 01:25:49Z]

  setup do
    payload =
      Kinds.new(
        Name.new!("а"),
        :done,
        %Item{name: Name.new!("п")},
        %DerivedFixture.Mark.Star{size: 2},
        [Name.new!("б")],
        MapSet.new([Name.new!("в")]),
        %{Name.new!("к") => 1},
        3
      )

    event = Event.new(payload, EventFixture.AggID.new(), Version.new!(1), EventFixture.ActorID.new(), at())

    %{event: event}
  end

  test "вид × операция: каждый вид проходит new/N, dump и load", %{event: event} do
    wire = Facade.dump(event)

    assert wire["payload"] == %{
             "prim" => "а",
             "enum" => :done,
             "entity" => %{"name" => "п"},
             "union" => %{"type" => "star", "fields" => %{"size" => 2}},
             "list" => ["б"],
             "set" => ["в"],
             "map" => %{"к" => 1},
             "type" => 3
           }

    for kind <- Field.kinds(:payload) do
      assert Map.has_key?(wire["payload"], Atom.to_string(kind)), "нет wire для вида #{kind}"
    end

    assert Facade.load(Event, wire) == {:ok, event}
    assert Facade.load(Event, Jason.decode!(Jason.encode!(wire))) == {:ok, event}
  end

  test "вид × операция: голова new/N закрывает вид каждого поля" do
    fields = Kinds.__es_payload_fields__()
    args = payload_args()

    for {kind, bad} <- bad_values() do
      index = Enum.find_index(fields, &(&1.name == kind))
      bad_args = List.replace_at(args, index, bad)

      assert_raise FunctionClauseError, fn -> apply(Kinds, :new, bad_args) end
    end
  end

  # ---

  defp payload_args do
    [
      Name.new!("а"),
      :done,
      %Item{name: Name.new!("п")},
      %DerivedFixture.Mark.Star{size: 2},
      [Name.new!("б")],
      MapSet.new([Name.new!("в")]),
      %{Name.new!("к") => 1},
      3
    ]
  end

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

  defp at, do: Core.Es.Event.At.new!(@at)
end
