defmodule Core.Es.Event.PayloadRoleTest do
  use ExUnit.Case, async: true

  alias Core.Es.Event.At
  alias Core.EventFixture.ActorID
  alias Core.EventFixture.AggID
  alias Core.EventFixture.Name
  alias Core.PayloadRoleFixture.Codec, as: RoleCodec
  alias Core.PayloadRoleFixture.Entity
  alias Core.PayloadRoleFixture.Event
  alias Core.PayloadRoleFixture.Event.ViewPayload
  alias Core.PayloadRoleFixture.Single
  alias Core.Version

  @at ~U[2026-11-19 12:00:00Z]

  describe "структура по полям с ручным new/N" do
    test "кодируется своим плагином: default поля подставляет загрузка плагина" do
      event = struct_payload_event()
      wire = json(RoleCodec.dump(event))

      assert wire["payload"] == %{"name" => "Склад", "status" => "draft"}

      wire = update_in(wire, ["payload"], &Map.delete(&1, "status"))

      assert {:ok, %Event.StructPayload{payload: %Entity{status: :draft}}} =
               RoleCodec.load(Event.StructPayload, wire)
    end

    test "subject: :aggregate_id проверяется при use Core.Es.Event" do
      assert_raise CompileError,
                   ~r/^Es\.Event: payload: поле contact нагрузки .*Sealed объявлено с subject: :aggregate_id/,
                   fn ->
                     Code.eval_quoted(
                       quote do
                         defmodule Core.Es.Event.PayloadRoleTest.NonUUIDFamily do
                           use Core.Es.Event.Family,
                             aggregate: Core.EsFixture.Account,
                             aggregate_id: Core.EsFixture.Account.Name,
                             by: Core.EsFixture.UserID,
                             codec: Core.EsFixture.Account.Event.Codec

                           @type t :: struct()
                         end

                         defmodule Core.Es.Event.PayloadRoleTest.SealedEvent do
                           use Core.Es.Event,
                             family: Core.Es.Event.PayloadRoleTest.NonUUIDFamily,
                             payload: Core.PayloadRoleFixture.Sealed
                         end
                       end
                     )
                   end
    end
  end

  describe "однополевое представление" do
    test "не нагрузка по полям: дамп — плагином View, load — отказ dump-only плагина" do
      event = view_payload_event()
      wire = json(RoleCodec.dump(event))

      assert wire["payload"] == %{"status" => "draft"}

      assert_raise ArgumentError, ~r/dump-only плагин/, fn -> RoleCodec.load(Event.ViewPayload, wire) end
    end
  end

  describe "вложенная нагрузка" do
    test "маркер роли читается при сборке кодека: dump/load по полям" do
      payload = Event.NestedPayload.Payload.new(Name.new!("Склад"))

      event =
        Event.NestedPayload.new(payload, AggID.new(), Version.new(), ActorID.new(), At.new!(@at))

      wire = json(RoleCodec.dump(event))

      assert wire["payload"] == %{"name" => "Склад"}
      assert RoleCodec.load(Event.NestedPayload, wire) == {:ok, event}
    end
  end

  # ---

  defp struct_payload_event do
    Event.StructPayload.new(
      Entity.new(Name.new!("Склад"), :draft),
      AggID.new(),
      Version.new(),
      ActorID.new(),
      At.new!(@at)
    )
  end

  defp view_payload_event do
    ViewPayload.new(
      %Single{status: :draft},
      AggID.new(),
      Version.new(),
      ActorID.new(),
      At.new!(@at)
    )
  end

  defp json(wire), do: Jason.decode!(Jason.encode!(wire))
end
