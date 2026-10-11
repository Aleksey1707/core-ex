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
               {:mark, {:union, DerivedFixture.Mark}, false, "mark", :none},
               {:prev, {:union, DerivedFixture.Mark}, true, "prev", :none}
             ] =
               Event.Marked.Payload.__es_payload_fields__()
    end

    test "адрес вне семейства — ошибка load" do
      wire = put_in(json(InCodec.dump(event(Event.Marked, marked()))), ["payload", "mark", "type"], "cross")

      assert {:error, %Error{ns: :codec, code: :unknown_tag}} = InCodec.load(Event.Marked, wire)
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
                         defmodule Core.Es.Event.DerivedPayloadTest.ManualDump do
                           alias Core.DerivedFixture.Event

                           use Core.Es.Event.Codec,
                             event: Event,
                             type: "derived_manual_dump",
                             tags: %{Event.Located => "derived_manual_dump.located"}

                           def dump_payload(%Event.Located{payload: place}, _codec), do: %{"name" => place.name.value}
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
            defmodule Core.Es.Event.DerivedPayloadTest.ManualLoad do
              alias Core.DerivedFixture.Event

              use Core.Es.Event.Codec,
                event: Event,
                type: "derived_manual_load",
                tags: %{Event.Tagged => "derived_manual_load.tagged"}

              def dump_payload(%Event.Tagged{payload: name}, codec), do: codec.dump(name)

              def load_payload(Event.Tagged, wire, codec), do: codec.load(Core.EventFixture.Name, wire)
            end
          end
        )
      end
    end
  end

  defp renamed, do: Event.Renamed.Payload.new(Name.new!("Склад"), Name.new!("Отгрузка"))

  defp marked, do: Event.Marked.Payload.new(%DerivedFixture.Mark.Star{size: 3}, nil)

  defp place, do: %DerivedFixture.Place{name: Name.new!("Склад"), floor: 2}

  defp json(wire), do: Jason.decode!(Jason.encode!(wire))

  defp event(mod, payload) do
    mod.new(payload, AggID.new(), Version.new!(3), ActorID.new(), Core.Es.Event.At.new!(@at))
  end
end
