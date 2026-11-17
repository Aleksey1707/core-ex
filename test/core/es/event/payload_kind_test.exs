defmodule Core.Es.Event.PayloadKindTest do
  use ExUnit.Case, async: true

  alias Core.CodecFixture.Internal, as: InCodec
  alias Core.DerivedFixture
  alias Core.Es.Personal.Destroyed
  alias Core.Es.Personal.Marker
  alias Core.EsFixture.PayloadKinds
  alias Core.EventFixture
  alias Core.Field
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
    use Core.Struct, fields: [name: [prim: Core.Es.Event.PayloadKindTest.Name]]
  end

  defmodule Item.Codec do
    use Core.Codec.Plugin, types: [Core.Es.Event.PayloadKindTest.Item]
  end

  defmodule Kinds do
    use Core.Es.Event.Payload,
      fields: [
        prim: [prim: Core.Es.Event.PayloadKindTest.Name],
        enum: [enum: Core.Es.Event.PayloadKindTest.Status],
        entity: [entity: Core.Es.Event.PayloadKindTest.Item],
        union: [union: Core.DerivedFixture.Mark, personal: false],
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
    fields = Kinds.__core_fields__()
    args = payload_args()

    for {kind, bad} <- bad_values() do
      index = Enum.find_index(fields, &(&1.name == kind))
      bad_args = List.replace_at(args, index, bad)

      assert_raise FunctionClauseError, fn -> apply(Kinds, :new, bad_args) end
    end
  end

  test "вид с subject: × операция: new/N, dump и load дают уничтоженное значение" do
    event = subject_event()

    for kind <- Field.kinds(:payload) do
      key = Atom.to_string(kind)
      payload = %{event.payload | kind => %Destroyed{}}
      destroyed = %{event | payload: payload}

      assert_raise FunctionClauseError, fn ->
        apply(PayloadKinds.Payload, :new, List.replace_at(subject_args(), kind_index(kind), %Destroyed{}))
      end

      assert %{^key => %Marker{destroyed: true}} = PayloadKinds.Codec.dump(destroyed, InCodec)["payload"]

      wire = put_payload(subject_wire(), kind, %{"$pd" => nil})

      assert {:ok, %PayloadKinds.Changed{payload: %{^kind => %Destroyed{}}}} =
               PayloadKinds.Codec.load(PayloadKinds.Changed, wire, InCodec)
    end
  end

  defmodule Escalated do
    @moduledoc """
    Эскалация границы: ПДн-лист в `set:` и в ключе `map:` шифрует контейнер целиком; значения
    `map:` и элементы `list:` — по месту.
    """

    use Core.Es.Event.Payload,
      fields: [
        tags: [set: [prim: Core.PrimFixture.Personal]],
        by_kind: [
          map: [key: [type: :string, personal: true], value: [prim: Core.Es.Event.PayloadKindTest.Name]]
        ],
        by_value: [map: [key: [type: :string], value: [prim: Core.PrimFixture.Personal]]],
        phones: [list: [prim: Core.PrimFixture.Personal]]
      ]
  end

  defmodule Escalated.Family do
    use Core.Es.Event.Family,
      aggregate: Core.EventFixture,
      aggregate_id: Core.EventFixture.AggID,
      by: Core.EventFixture.ActorID,
      codec: Core.Es.Event.PayloadKindTest.Escalated.Codec

    @type t :: struct()
  end

  defmodule Escalated.Event do
    use Core.Es.Event,
      family: Core.Es.Event.PayloadKindTest.Escalated.Family,
      payload: Core.Es.Event.PayloadKindTest.Escalated
  end

  defmodule Escalated.Codec do
    use Core.Es.Event.Codec,
      family: Core.Es.Event.PayloadKindTest.Escalated.Family,
      type: "payload_escalated",
      tags: %{Core.Es.Event.PayloadKindTest.Escalated.Event => "payload_escalated.event"}
  end

  test "set: и ключ map: — маркер на контейнере; значение map: и элемент list: — по месту" do
    event = escalated_event()
    subject = InCodec.dump(event.aggregate_id)

    assert %{
             "tags" => %Marker{subject: ^subject, value: ["+7 900 000-00-01"]},
             "by_kind" => %Marker{subject: ^subject, value: %{"вид" => "и"}},
             "by_value" => %{"вид" => %Marker{subject: ^subject, value: "+7 900 000-00-02"}},
             "phones" => [%Marker{subject: ^subject, value: "+7 900 000-00-03"}]
           } = Escalated.Codec.dump(event, InCodec)["payload"]
  end

  test "load: уничтоженный контейнер — %Destroyed{} на месте контейнера, элемент и значение — по месту" do
    wire = Escalated.Codec.dump(escalated_event(), InCodec) |> destroyed_wire()

    assert {:ok, %Escalated.Event{payload: payload}} = Escalated.Codec.load(Escalated.Event, wire, InCodec)

    assert %Escalated{
             tags: %Destroyed{},
             by_kind: %Destroyed{},
             by_value: %{"вид" => %Destroyed{}},
             phones: [%Destroyed{}]
           } = payload
  end

  # ---

  defp escalated_event do
    payload =
      Escalated.new(
        MapSet.new([Core.PrimFixture.Personal.new!("+7 900 000-00-01")]),
        %{"вид" => Name.new!("и")},
        %{"вид" => Core.PrimFixture.Personal.new!("+7 900 000-00-02")},
        [Core.PrimFixture.Personal.new!("+7 900 000-00-03")]
      )

    Escalated.Event.new(payload, EventFixture.AggID.new(), Version.new!(1), EventFixture.ActorID.new(), at())
  end

  # Конверт после расшифровки уничтоженного ключа: маркер любого места — `{"$pd": null}`.
  defp destroyed_wire(%{"payload" => payload} = wire), do: %{wire | "payload" => destroy_markers(payload)}

  defp destroy_markers(%Marker{}), do: %{"$pd" => nil}

  defp destroy_markers(map) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {key, value} -> {key, destroy_markers(value)} end)

  defp destroy_markers(list) when is_list(list), do: Enum.map(list, &destroy_markers/1)
  defp destroy_markers(value), do: value

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

  defp subject_event do
    PayloadKinds.Changed.new(
      PayloadKinds.Payload.new(
        EventFixture.Name.new!("а"),
        :active,
        %DerivedFixture.Place{name: EventFixture.Name.new!("место"), floor: 1},
        %DerivedFixture.Mark.Star{size: 2},
        [EventFixture.Name.new!("б")],
        MapSet.new([EventFixture.Name.new!("в")]),
        %{EventFixture.Name.new!("к") => 1},
        %{"к" => 1}
      ),
      EventFixture.AggID.new(),
      Version.new!(1),
      EventFixture.ActorID.new(),
      at()
    )
  end

  defp subject_args do
    [
      EventFixture.Name.new!("а"),
      :active,
      %DerivedFixture.Place{name: EventFixture.Name.new!("место"), floor: 1},
      %DerivedFixture.Mark.Star{size: 2},
      [EventFixture.Name.new!("б")],
      MapSet.new([EventFixture.Name.new!("в")]),
      %{EventFixture.Name.new!("к") => 1},
      %{"к" => 1}
    ]
  end

  # Конверт после расшифровки: на месте маркера — его открытое wire-значение.
  defp subject_wire do
    dumped = PayloadKinds.Codec.dump(subject_event(), InCodec)

    payload =
      Map.new(dumped["payload"], fn
        {key, %Marker{value: value}} -> {key, value}
        {key, value} -> {key, value}
      end)

    %{dumped | "payload" => payload}
  end

  defp kind_index(kind), do: Enum.find_index(PayloadKinds.Payload.__core_fields__(), &(&1.name == kind))

  defp put_payload(wire, kind, value),
    do: Map.update!(wire, "payload", &Map.put(&1, Atom.to_string(kind), value))

  defp at, do: Core.Es.Event.At.new!(@at)
end
