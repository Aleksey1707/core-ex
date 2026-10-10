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

  describe "Event.Codec: ручная клауза для выводимой нагрузки" do
    test "never match у нагрузки-Prim и ValueChanged" do
      {_result, diagnostics} =
        Code.with_diagnostics(fn ->
          Code.eval_quoted(
            quote do
              defmodule Core.Es.Event.DerivedPayloadTest.NeverMatch do
                alias Core.DerivedFixture.Event

                use Core.Es.Event.Codec,
                  event: Event,
                  type: "derived_never_match",
                  tags: %{
                    Event.Tagged => "derived_never_match.tagged",
                    Event.Renamed => "derived_never_match.renamed"
                  }

                def dump_payload(%Event.Tagged{payload: payload}, codec), do: codec.dump(payload)

                def load_payload(Event.Renamed, _wire, _codec), do: {:error, :never}
              end
            end
          )
        end)

      assert [dump, load] = Enum.map(diagnostics, & &1.message)
      assert dump =~ ~r/never match: dump_payload\/2 для .*Event.Tagged выводится по нагрузке/
      assert load =~ ~r/never match: load_payload\/3 для .*Event.Renamed выводится по нагрузке/
    end
  end

  defp renamed, do: Event.Renamed.Payload.new(Name.new!("Склад"), Name.new!("Отгрузка"))

  defp json(wire), do: Jason.decode!(Jason.encode!(wire))

  defp event(mod, payload) do
    mod.new(payload, AggID.new(), Version.new!(3), ActorID.new(), Core.Es.Event.At.new!(@at))
  end
end
