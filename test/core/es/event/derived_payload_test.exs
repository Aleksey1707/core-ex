defmodule Core.Es.Event.DerivedPayloadTest do
  use ExUnit.Case, async: true

  alias Core.CodecFixture.Internal, as: InCodec
  alias Core.DerivedFixture
  alias Core.DerivedFixture.Event
  alias Core.Error
  alias Core.EventFixture.ActorID
  alias Core.EventFixture.AggID
  alias Core.EventFixture.Name
  alias Core.Version

  @at ~U[2026-09-14 01:25:49Z]

  describe "Event.Codec: нагрузка-Prim" do
    test "нагрузка в конверте — голое значение, как codec.dump(prim)" do
      tagged = event(Event.Tagged, Name.new!("Отгрузка"))

      assert InCodec.dump(tagged)["payload"] == "Отгрузка"
    end

    test "dump/load через фасад — round-trip" do
      tagged = event(Event.Tagged, Name.new!("Отгрузка"))
      wire = Jason.decode!(Jason.encode!(InCodec.dump(tagged)))

      assert InCodec.load(Event.Tagged, wire) == {:ok, tagged}
      assert InCodec.load(DerivedFixture.Event, wire) == {:ok, tagged}
    end

    test "невалидное значение — ошибка load" do
      wire = InCodec.dump(event(Event.Tagged, Name.new!("Отгрузка")))

      assert {:error, %Error{}} = InCodec.load(Event.Tagged, %{wire | "payload" => ""})
    end
  end

  describe "Event.Codec: Es.ValueChanged" do
    test "Prim-тип — old_value / new_value через фасад" do
      renamed = event(Event.Renamed, Event.Renamed.Payload.new(Name.new!("Склад"), Name.new!("Отгрузка")))

      assert InCodec.dump(renamed)["payload"] == %{"old_value" => "Склад", "new_value" => "Отгрузка"}
      assert InCodec.load(DerivedFixture.Event, json(InCodec.dump(renamed))) == {:ok, renamed}
    end

    test "nilable: true — nil в обе стороны" do
      note = DerivedFixture.Note.new!("у окна")
      added = event(Event.NoteChanged, Event.NoteChanged.Payload.new(nil, note))
      removed = event(Event.NoteChanged, Event.NoteChanged.Payload.new(note, nil))

      assert InCodec.dump(added)["payload"] == %{"old_value" => nil, "new_value" => "у окна"}
      assert InCodec.load(Event.NoteChanged, json(InCodec.dump(added))) == {:ok, added}
      assert InCodec.load(Event.NoteChanged, json(InCodec.dump(removed))) == {:ok, removed}
    end

    test "enum-тип — атом в wire, cast при загрузке" do
      changed = event(Event.StatusChanged, Event.StatusChanged.Payload.new(:draft, :active))

      assert InCodec.dump(changed)["payload"] == %{"old_value" => :draft, "new_value" => :active}
      assert InCodec.load(Event.StatusChanged, json(InCodec.dump(changed))) == {:ok, changed}

      wire = put_in(json(InCodec.dump(changed)), ["payload", "new_value"], "archived")

      assert {:error, %Error{}} = InCodec.load(Event.StatusChanged, wire)
    end

    test "без nilable: — nil в wire не грузится" do
      wire = put_in(json(InCodec.dump(event(Event.Renamed, renamed()))), ["payload", "old_value"], nil)

      assert {:error, %Error{}} = InCodec.load(Event.Renamed, wire)
    end
  end

  describe "Event.Codec: нагрузка по полям с union:" do
    test "new/N — вариант семейства; не struct в голове — FunctionClauseError" do
      star = %DerivedFixture.Mark.Star{size: 3}

      assert Event.Marked.Payload.new(star, nil) == %Event.Marked.Payload{mark: star, prev: nil}
      assert_raise FunctionClauseError, fn -> Event.Marked.Payload.new(Map.new(size: 3), nil) end
      assert_raise FunctionClauseError, fn -> Event.Marked.Payload.new(star, Map.new(color: "red")) end
    end

    test "вариант в форме адреса в конверте, round-trip через фасад" do
      payload = Event.Marked.Payload.new(%DerivedFixture.Mark.Star{size: 3}, %DerivedFixture.Mark.Dot{color: "red"})
      marked = event(Event.Marked, payload)

      assert InCodec.dump(marked)["payload"] == %{
               "mark" => %{"type" => "star", "fields" => %{"size" => 3}},
               "prev" => %{"type" => "dot", "fields" => %{"color" => "red"}}
             }

      assert InCodec.load(DerivedFixture.Event, json(InCodec.dump(marked))) == {:ok, marked}

      unmarked = event(Event.Marked, %{payload | prev: nil})

      assert InCodec.load(Event.Marked, json(InCodec.dump(unmarked))) == {:ok, unmarked}
    end

    test "спека нагрузки — {:union, Family}" do
      assert [
               %Core.Codec.Field{
                 name: :mark,
                 spec: {:union, DerivedFixture.Mark}
               },
               %Core.Codec.Field{
                 name: :prev,
                 spec: {:union, DerivedFixture.Mark}
               }
             ] =
               Event.Marked.Payload.__es_payload_fields__()
    end

    test "адрес вне семейства — ошибка load" do
      wire = put_in(json(InCodec.dump(event(Event.Marked, marked()))), ["payload", "mark", "type"], "cross")

      assert {:error, %Error{ns: :codec, code: :unknown_tag}} = InCodec.load(Event.Marked, wire)
    end
  end

  describe "Event.Codec: нагрузка по полям с set: и map:" do
    test "new/N принимает MapSet и map; не тот вид — мимо головы" do
      tags = MapSet.new([Name.new!("Склад")])
      stock = %{Name.new!("Склад") => 2}

      assert Event.Grouped.Payload.new(tags, stock) == %Event.Grouped.Payload{tags: tags, stock: stock}

      assert_raise FunctionClauseError, fn ->
        Event.Grouped.Payload.new(Function.identity([Name.new!("Склад")]), stock)
      end

      assert_raise FunctionClauseError, fn -> Event.Grouped.Payload.new(tags, Function.identity(tags)) end
    end

    test "@type t — MapSet.t/1 элемента и словарь с видами ключа и значения" do
      {:ok, types} = Code.Typespec.fetch_types(Event.Grouped.Payload)
      fields = struct_type_fields(types)

      assert fields[:tags] == "MapSet.t(Core.EventFixture.Name.t())"
      assert fields[:stock] == "%{optional(Core.EventFixture.Name.t()) => non_neg_integer()}"
    end

    test "dump: множество — список по wire элемента, словарь — объект по wire ключа" do
      grouped = grouped_event(MapSet.new([Name.new!("Склад"), Name.new!("Отгрузка")]), %{Name.new!("Склад") => 2})

      assert %{"tags" => ["Отгрузка", "Склад"], "stock" => %{"Склад" => 2}} = InCodec.dump(grouped)["payload"]
    end

    test "round-trip через JSON — по модулю события и по семейству" do
      grouped =
        grouped_event(MapSet.new([Name.new!("Склад"), Name.new!("Отгрузка")]), %{
          Name.new!("Склад") => 2,
          Name.new!("Цех") => 0
        })

      wire = json(InCodec.dump(grouped))

      assert InCodec.load(Event.Grouped, wire) == {:ok, grouped}
      assert InCodec.load(DerivedFixture.Event, wire) == {:ok, grouped}
    end

    test "порядок множества — по wire элемента, а не по обходу MapSet" do
      values = for i <- 1..40, do: "метка #{i}"
      tags = MapSet.new(values, &Name.new!/1)

      refute Enum.map(tags, &Name.value/1) == Enum.sort(values)
      assert InCodec.dump(grouped_event(tags, %{}))["payload"]["tags"] == Enum.sort(values)
    end

    test "повторы в wire множества схлопываются" do
      wire = put_in(json(InCodec.dump(grouped_event(MapSet.new(), %{}))), ["payload", "tags"], ["Склад", "Склад"])

      assert {:ok, %Event.Grouped{payload: %{tags: tags}}} = InCodec.load(Event.Grouped, wire)
      assert tags == MapSet.new([Name.new!("Склад")])
    end

    test "ошибка load — путь: индекс элемента множества, ключ словаря" do
      wire = json(InCodec.dump(grouped_event(MapSet.new(), %{})))

      assert {:error, %Error{ns: :codec, detail: %{field: :tags, index: 1}}} =
               InCodec.load(Event.Grouped, put_in(wire, ["payload", "tags"], ["Склад", ""]))

      assert {:error, %Error{ns: :codec, detail: %{field: :stock, key: ""}}} =
               InCodec.load(Event.Grouped, put_in(wire, ["payload", "stock"], %{"" => 1}))
    end
  end

  describe "Event.Codec: нагрузка-сущность с ручным плагином" do
    test "нагрузка в конверте — дамп плагина сущности" do
      located = event(Event.Located, place())

      assert InCodec.dump(located)["payload"] == %{"name" => "Склад", "level" => 2}
    end

    test "dump/load через фасад — round-trip по модулю события и по семейству" do
      located = event(Event.Located, place())
      wire = json(InCodec.dump(located))

      assert InCodec.load(Event.Located, wire) == {:ok, located}
      assert InCodec.load(DerivedFixture.Event, wire) == {:ok, located}
    end

    test "ошибка плагина сущности — ошибка load события" do
      wire = put_in(json(InCodec.dump(event(Event.Located, place()))), ["payload", "name"], "")

      assert {:error, %Error{}} = InCodec.load(Event.Located, wire)
    end
  end

  describe "Event.Codec: ручные клаузы нагрузки" do
    test "dump_payload/2 в кодеке событий — CompileError с подсказкой о плагине" do
      assert_raise CompileError,
                   ~r/объявляет dump_payload\/2 \(строка \d+\) — нагрузку события кодирует плагин её типа/,
                   fn ->
                     Code.eval_quoted(
                       quote do
                         unquote(
                           Core.EventFixture.family_ast(Core.Es.Event.DerivedPayloadTest.ManualDump,
                             Located: DerivedFixture.Place
                           )
                         )

                         defmodule Core.Es.Event.DerivedPayloadTest.ManualDump do
                           use Core.Es.Event.Codec,
                             family: __MODULE__.Family,
                             type: "derived_manual_dump",
                             tags: %{__MODULE__.Located => "derived_manual_dump.located"}

                           def dump_payload(%__MODULE__.Located{payload: place}, _codec),
                             do: %{"name" => place.name.value}
                         end
                       end
                     )
                   end
    end

    test "dump_payload/2 и load_payload/3 в кодеке событий — одна CompileError на обе" do
      message = ~r/объявляет dump_payload\/2 \(строка \d+\), load_payload\/3 \(строка \d+\) — нагрузку события/

      assert_raise CompileError, message, fn ->
        Code.eval_quoted(
          quote do
            unquote(Core.EventFixture.family_ast(Core.Es.Event.DerivedPayloadTest.ManualLoad, Tagged: Name))

            defmodule Core.Es.Event.DerivedPayloadTest.ManualLoad do
              use Core.Es.Event.Codec,
                family: __MODULE__.Family,
                type: "derived_manual_load",
                tags: %{__MODULE__.Tagged => "derived_manual_load.tagged"}

              def dump_payload(%__MODULE__.Tagged{payload: name}, codec), do: codec.dump(name)

              def load_payload(__MODULE__.Tagged, wire, codec), do: codec.load(Core.EventFixture.Name, wire)
            end
          end
        )
      end
    end
  end

  defp renamed, do: Event.Renamed.Payload.new(Name.new!("Склад"), Name.new!("Отгрузка"))

  defp marked, do: Event.Marked.Payload.new(%DerivedFixture.Mark.Star{size: 3}, nil)

  defp place, do: %DerivedFixture.Place{name: Name.new!("Склад"), floor: 2}

  defp grouped_event(tags, stock), do: event(Event.Grouped, Event.Grouped.Payload.new(tags, stock))

  defp json(wire), do: Jason.decode!(Jason.encode!(wire))

  defp event(mod, payload) do
    mod.new(payload, AggID.new(), Version.new!(3), ActorID.new(), Core.Es.Event.At.new!(@at))
  end

  defp struct_type_fields(types) do
    {:type, {:t, {:type, _, :map, entries}, []}} = Enum.find(types, &match?({:type, {:t, _, []}}, &1))

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
