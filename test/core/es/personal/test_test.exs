defmodule Core.Es.Personal.TestTest do
  use ExUnit.Case, async: true

  alias Core.CodecFixture.Internal, as: InCodec
  alias Core.Es
  alias Core.Es.Personal
  alias Core.Es.Personal.Destroyed
  alias Core.EsFixture.Account
  alias Core.EsFixture.Itinerary
  alias Core.EsFixture.Itinerary.Event.Planned
  alias Core.EsFixture.Itinerary.Event.RecipientChanged
  alias Core.EsFixture.UserID
  alias Core.EventFixture
  alias Core.Version

  describe "destroyed/2" do
    test "событие — %Destroyed{} во всех полях с subject:, остальное как есть" do
      person_id = EventFixture.PersonID.new()
      event = EventFixture.contact_set(person_id, "+7 900 000-00-00", "Звонить после обеда")

      assert %EventFixture.Event.ContactSet{payload: payload} = destroyed = Personal.Test.destroyed(event)
      assert %{person_id: ^person_id, contact: %Destroyed{}, note: %Destroyed{}} = payload
      assert %{destroyed | payload: event.payload} == event
    end

    test "перечисленные поля — уничтожены только они" do
      event = EventFixture.contact_set(EventFixture.PersonID.new(), "+7 900 000-00-00", "Звонить после обеда")

      assert %{payload: %{contact: %Destroyed{}, note: note}} = Personal.Test.destroyed(event, [:contact])
      assert note == event.payload.note
    end

    test "нагрузка — %Destroyed{} в полях с subject:" do
      payload = Account.Event.HolderSet.Payload.new(Account.Holder.new!("Иван Петров"))

      assert %Account.Event.HolderSet.Payload{holder: %Destroyed{}} = Personal.Test.destroyed(payload)
    end

    test "nil необязательного поля остаётся nil — незаполненное значение не шифруется" do
      event = EventFixture.contact_set(nil, nil, "Звонить после обеда")

      assert %{payload: %{contact: nil, note: %Destroyed{}}} = Personal.Test.destroyed(event)
    end

    test "поле без subject: — ArgumentError" do
      event = EventFixture.contact_set(EventFixture.PersonID.new(), "+7 900 000-00-00", "Звонить после обеда")

      assert_raise ArgumentError, ~r/person_id.*без subject:/, fn ->
        Personal.Test.destroyed(event, [:person_id])
      end
    end

    test "нагрузка без полей с subject: — ArgumentError" do
      assert_raise ArgumentError, ~r/нет полей с subject:/, fn ->
        Personal.Test.destroyed(EventFixture.created())
      end
    end

    test "вложенные места списка — %Destroyed{} на каждом, открытые поля шага целы" do
      event = planned([step("sms", "pending", 1), step("push", "sent", 2)])

      assert %Planned{payload: %Planned.Payload{steps: [first, second]}} = Personal.Test.destroyed(event)

      assert %{recipient: %Destroyed{}, content: %Destroyed{}, channel: "sms", status: "pending"} = first
      assert %{recipient: %Destroyed{}, content: %Destroyed{}, channel: "push", status: "sent"} = second
    end
  end

  describe "fixtures/1" do
    test "открытое wire-значение и {\"$pd\": null} на месте ПДн-значений, конверт общий" do
      person_id = EventFixture.PersonID.new()
      event = EventFixture.contact_set(person_id, "+7 900 000-00-00", "Звонить после обеда")
      person = InCodec.dump(person_id)

      assert %{open: open, destroyed: destroyed} = Personal.Test.fixtures(event)

      assert %{"type" => "fixture.contact_set", "payload" => open_payload} = open
      assert open_payload == %{"person_id" => person, "contact" => "+7 900 000-00-00", "note" => "Звонить после обеда"}

      assert destroyed["payload"] == %{
               "person_id" => person,
               "contact" => %{"$pd" => nil},
               "note" => %{"$pd" => nil}
             }

      assert Map.delete(destroyed, "payload") == Map.delete(open, "payload")
    end

    test "тела грузятся фасадом в событие и в его уничтоженный вариант" do
      event = EventFixture.contact_set(EventFixture.PersonID.new(), "+7 900 000-00-00", "Звонить после обеда")
      %{open: open, destroyed: destroyed} = Personal.Test.fixtures(event)

      assert InCodec.load(EventFixture.Event, open) == {:ok, event}
      assert InCodec.load(EventFixture.Event, destroyed) == {:ok, Personal.Test.destroyed(event)}
    end

    test "событие без полей с subject: — уничтоженного варианта нет" do
      event = EventFixture.created()

      assert %{open: %{"type" => "fixture.created", "payload" => %{"name" => "Приёмка"}}, destroyed: nil} =
               Personal.Test.fixtures(event)

      assert %{destroyed: nil} = Personal.Test.fixtures(EventFixture.closed())
    end

    test "вложенные места: открытая форма — открытые значения, уничтоженная — {\"$pd\": null} по пути" do
      event = planned([step("sms", "pending", 1), step("push", "sent", 2)])
      %{open: open, destroyed: destroyed} = Personal.Test.fixtures(event)

      assert %{
               "payload" => %{
                 "steps" => [
                   %{"recipient" => "Иван", "content" => "Код", "channel" => "sms"},
                   %{"recipient" => "Иван", "content" => "Код", "channel" => "push"}
                 ]
               }
             } = open

      assert %{
               "payload" => %{
                 "steps" => [
                   %{"recipient" => %{"$pd" => nil}, "content" => %{"$pd" => nil}, "channel" => "sms"},
                   %{"recipient" => %{"$pd" => nil}, "content" => %{"$pd" => nil}, "channel" => "push"}
                 ]
               }
             } = destroyed

      assert InCodec.load(Planned, open) == {:ok, event}
      assert InCodec.load(Planned, destroyed) == {:ok, Personal.Test.destroyed(event)}
    end

    test "нагрузка-Prim: уничтоженная форма — {\"$pd\": null} в корне payload" do
      event = recipient_changed()
      %{open: open, destroyed: destroyed} = Personal.Test.fixtures(event)

      assert %{"payload" => "Иван"} = open
      assert %{"payload" => %{"$pd" => nil}} = destroyed
    end
  end

  # ---

  defp planned(steps) do
    Planned.new(
      Planned.Payload.new(steps),
      Itinerary.ID.new(),
      Version.new!(1),
      UserID.new(),
      Es.Event.At.new!(~U[2026-11-18 09:00:00.000000Z])
    )
  end

  defp step(channel, status, attempts),
    do: %Itinerary.Step{
      channel: channel,
      status: status,
      attempts: attempts,
      recipient: Itinerary.Recipient.new!("Иван"),
      content: Itinerary.Content.new!("Код")
    }

  defp recipient_changed do
    alias Core.EsFixture.Itinerary.Event.RecipientChanged

    RecipientChanged.new(
      Itinerary.Recipient.new!("Иван"),
      Itinerary.ID.new(),
      Version.new!(1),
      UserID.new(),
      Es.Event.At.new!(~U[2026-11-18 09:00:00.000000Z])
    )
  end
end
