defmodule Core.Es.Event.CodecPersonalTest do
  use ExUnit.Case, async: true

  alias Core.CodecFixture.Internal, as: InCodec
  alias Core.DerivedFixture.Event.Contacted
  alias Core.Error
  alias Core.Es
  alias Core.Es.Personal
  alias Core.Es.Personal.Destroyed
  alias Core.Es.Personal.Marker
  alias Core.EsFixture.Account
  alias Core.EsFixture.UserID
  alias Core.EventFixture
  alias Core.Version

  @holder "Иван Петров"
  @contact "+7 900 000-00-00"

  describe "__es_subjects__/0" do
    test "поля subject: по модулю события; событий без них в карте нет" do
      assert Account.Event.Codec.__es_subjects__() == %{Account.Event.HolderSet => [holder: :aggregate_id]}

      assert EventFixture.Event.Codec.__es_subjects__() == %{
               EventFixture.Event.ContactSet => [contact: :person_id, note: :aggregate_id]
             }
    end
  end

  describe "dump" do
    test "на месте ПДн-значения — маркер: субъект и wire-значение" do
      event = holder_set(Account.Holder.new!(@holder))

      assert %{"payload" => %{"holder" => %Marker{} = marker}} = InCodec.dump(event)
      assert marker == %Marker{subject: InCodec.dump(event.aggregate_id), value: @holder}
    end

    test "у каждого поля свой субъект" do
      person_id = EventFixture.PersonID.new()
      event = EventFixture.contact_set(person_id, @contact, "Звонить после обеда")

      assert %{"contact" => contact, "note" => note, "person_id" => person} = InCodec.dump(event)["payload"]
      assert person == InCodec.dump(person_id)
      assert contact == %Marker{subject: person, value: @contact}
      assert note == %Marker{subject: InCodec.dump(event.aggregate_id), value: "Звонить после обеда"}
    end

    test "nil необязательного ПДн-поля остаётся nil" do
      event = EventFixture.contact_set(nil, nil, "Звонить после обеда")

      assert %{"contact" => nil, "person_id" => nil} = InCodec.dump(event)["payload"]
    end

    test "на месте уничтоженного значения — маркер уничтоженного значения" do
      event = holder_set(%Destroyed{})

      assert %{"payload" => %{"holder" => %Marker{destroyed: true, value: nil} = marker}} = InCodec.dump(event)
      assert marker.subject == InCodec.dump(event.aggregate_id)
    end

    test "непустое ПДн-значение при nil субъекта — мимо головы dump" do
      event = EventFixture.contact_set(nil, nil, "Звонить после обеда")
      payload = %{event.payload | contact: EventFixture.Contact.new!(@contact)}

      assert_raise FunctionClauseError, fn -> InCodec.dump(%{event | payload: payload}) end
    end

    test "ПДн-значение с субъектом :aggregate_id при nil агрегата — мимо головы dump" do
      event = holder_set(Account.Holder.new!(@holder))

      assert_raise FunctionClauseError, fn -> InCodec.dump(%{event | aggregate_id: nil}) end
    end

    test "JSON маркер не кодирует, и значения в тексте нет" do
      dumped = InCodec.dump(holder_set(Account.Holder.new!(@holder)))

      error = assert_raise Protocol.UndefinedError, fn -> Jason.encode!(dumped) end
      refute Exception.message(error) =~ @holder
    end

    test "inspect/1 маркера — только субъект" do
      marker = %Marker{subject: "01a09d85-3b0d-7db9-b527-fbb1a72396e0", value: @holder}

      assert inspect(marker) == ~s(#Core.Es.Personal.Marker<subject: "01a09d85-3b0d-7db9-b527-fbb1a72396e0">)
      assert inspect(%{marker | value: nil, destroyed: true}) =~ "destroyed"
    end

    test "фасад уничтоженное значение не дампит" do
      assert_raise FunctionClauseError, fn -> InCodec.dump(Function.identity(%Destroyed{})) end
    end
  end

  describe "load" do
    test "{\"$pd\": null} в поле с subject: → %Destroyed{} на месте поля" do
      wire = put_payload(holder_wire(), %{"holder" => %{"$pd" => nil}})

      assert {:ok, %Account.Event.HolderSet{payload: %{holder: %Destroyed{}}}} =
               InCodec.load(Account.Event, wire)
    end

    test "уничтожен один субъект, второй читается" do
      wire = put_payload(contact_wire(), %{"contact" => %{"$pd" => nil}})

      assert {:ok, %EventFixture.Event.ContactSet{payload: payload}} = InCodec.load(EventFixture.Event, wire)
      assert %Destroyed{} = payload.contact
      assert EventFixture.Note.value(payload.note) == "Звонить после обеда"
    end

    test "{\"$pd\": null} в поле без subject: — :invalid_value" do
      wire = put_payload(contact_wire(), %{"person_id" => %{"$pd" => nil}})

      assert {:error, %Error{kind: :domain, ns: :codec, code: :invalid_value, detail: %{field: :person_id}}} =
               InCodec.load(EventFixture.Event, wire)
    end

    test ~s({"$pd": "<строка>"} — :sealed_personal_value) do
      wire = put_payload(holder_wire(), %{"holder" => %{"$pd" => "AQID"}})

      assert {:error, %Error{kind: :domain, ns: :codec, code: :sealed_personal_value, detail: %{field: :holder}}} =
               InCodec.load(Account.Event, wire)
    end

    test "шифротекст в поле без subject: — тоже :sealed_personal_value" do
      wire = put_payload(contact_wire(), %{"person_id" => %{"$pd" => "AQID"}})

      assert {:error, %Error{code: :sealed_personal_value}} = InCodec.load(EventFixture.Event, wire)
    end

    test "null необязательного ПДн-поля → nil" do
      wire = put_payload(contact_wire(), %{"person_id" => nil, "contact" => nil})

      assert {:ok, %EventFixture.Event.ContactSet{payload: %{person_id: nil, contact: nil}}} =
               InCodec.load(EventFixture.Event, wire)
    end

    test "записанное открытым грузится как раньше" do
      assert {:ok, %Account.Event.HolderSet{payload: payload}} = InCodec.load(Account.Event, holder_wire())
      assert Account.Holder.value(payload.holder) == @holder
    end

    test "detail ошибки load под полем с subject: редактируется и у не персонального Prim" do
      long = String.duplicate("заметка", 40)
      wire = put_payload(contact_wire(), %{"note" => long})

      assert {:error, %Error{ns: :prim} = error} = InCodec.load(EventFixture.Event, wire)
      refute inspect(error) =~ "заметка"
    end
  end

  describe "нагрузка" do
    test "new/N не принимает %Destroyed{}" do
      assert_raise FunctionClauseError, fn -> Account.Event.HolderSet.Payload.new(Function.identity(%Destroyed{})) end
    end

    test "guard new/N отвергает nil в поле-субъекте при непустом ПДн-значении" do
      contact = EventFixture.Contact.new!(@contact)
      note = EventFixture.Note.new!("Звонить после обеда")

      assert_raise FunctionClauseError, fn -> EventFixture.Event.ContactSet.Payload.new(nil, contact, note) end
    end

    test "inspect/1 нагрузки не выводит поля с subject:" do
      payload =
        EventFixture.Event.ContactSet.Payload.new(
          EventFixture.PersonID.new(),
          EventFixture.Contact.new!(@contact),
          EventFixture.Note.new!("Звонить после обеда")
        )

      refute inspect(payload) =~ "contact"
      refute inspect(payload) =~ "Звонить"
      assert inspect(payload) =~ "person_id"
    end
  end

  describe "set: и map: с subject:" do
    test "dump: маркер множества — список по wire элемента, маркер словаря — объект" do
      event = contacted(["+7 900 000-00-02", "+7 900 000-00-01"], %{"дом" => "+7 900 000-00-03"})
      subject = InCodec.dump(event.aggregate_id)

      assert %{"contacts" => contacts, "contact_by_kind" => by_kind} = InCodec.dump(event)["payload"]
      assert contacts == %Marker{subject: subject, value: ["+7 900 000-00-01", "+7 900 000-00-02"]}
      assert by_kind == %Marker{subject: subject, value: %{"дом" => "+7 900 000-00-03"}}
    end

    test "открытый текст маркера множества — по wire элемента до шифрования, а не по обходу MapSet" do
      values = for i <- 10..49, do: "+7 900 000-00-#{i}"
      event = contacted(values, nil)

      refute Enum.map(event.payload.contacts, &EventFixture.Contact.value/1) == values
      assert %Marker{value: ^values} = InCodec.dump(event)["payload"]["contacts"]
    end

    test "открытое значение после расшифровки — round-trip; nil необязательного словаря — nil" do
      event = contacted(["+7 900 000-00-01", "+7 900 000-00-02"], %{"дом" => "+7 900 000-00-03"})

      assert InCodec.load(Contacted, Personal.Test.fixtures(event).open) == {:ok, event}

      without = contacted(["+7 900 000-00-01"], nil)

      assert InCodec.load(Contacted, Personal.Test.fixtures(without).open) == {:ok, without}
    end

    test "{\"$pd\": null} → %Destroyed{} на месте множества и словаря целиком" do
      %{destroyed: wire} = Personal.Test.fixtures(contacted(["+7 900 000-00-01"], %{}))

      assert %{"contacts" => %{"$pd" => nil}, "contact_by_kind" => %{"$pd" => nil}} = wire["payload"]

      assert {:ok, %Contacted{payload: %{contacts: %Destroyed{}, contact_by_kind: %Destroyed{}}}} =
               InCodec.load(Contacted, wire)
    end

    test "detail ошибки элемента и значения словаря редактируется" do
      long = String.duplicate("контакт", 20)
      wire = Personal.Test.fixtures(contacted(["+7 900 000-00-01"], nil)).open

      assert {:error, %Error{} = error} = InCodec.load(Contacted, put_payload(wire, %{"contacts" => [long]}))
      refute inspect(error) =~ "контакт"

      assert {:error, %Error{} = error} =
               InCodec.load(Contacted, put_payload(wire, %{"contact_by_kind" => %{"дом" => long}}))

      refute inspect(error) =~ "контакт"
    end

    test "путь ошибки (индекс элемента, ключ словаря) при редакции остаётся, редактируется значение" do
      long = String.duplicate("контакт", 20)
      wire = Personal.Test.fixtures(contacted(["+7 900 000-00-01"], nil)).open

      assert {:error, %Error{detail: %{field: :contacts, index: 1}, parent: %Error{detail: detail}}} =
               InCodec.load(Contacted, put_payload(wire, %{"contacts" => ["+7 900 000-00-01", long]}))

      assert detail in [:redacted, {:redacted, byte_size(long)}]

      assert {:error, %Error{detail: %{field: :contact_by_kind, key: "дом"}, parent: %Error{detail: detail}}} =
               InCodec.load(Contacted, put_payload(wire, %{"contact_by_kind" => %{"дом" => long}}))

      assert detail in [:redacted, {:redacted, byte_size(long)}]
    end

    test "new/N не принимает %Destroyed{} на месте множества и словаря" do
      contacts = MapSet.new([EventFixture.Contact.new!("+7 900 000-00-01")])

      assert_raise FunctionClauseError, fn -> Contacted.Payload.new(Function.identity(%Destroyed{}), nil) end
      assert_raise FunctionClauseError, fn -> Contacted.Payload.new(contacts, Function.identity(%Destroyed{})) end
    end
  end

  # ---

  defp contacted(contacts, by_kind) do
    payload =
      Contacted.Payload.new(
        MapSet.new(contacts, &EventFixture.Contact.new!/1),
        if(by_kind, do: Map.new(by_kind, fn {kind, value} -> {kind, EventFixture.Contact.new!(value)} end))
      )

    Contacted.new(payload, EventFixture.AggID.new(), Version.new(), EventFixture.ActorID.new(), Es.Event.At.now!())
  end

  defp holder_set(holder) do
    Account.Event.HolderSet.new(
      %Account.Event.HolderSet.Payload{holder: holder},
      Account.ID.new(),
      Version.new(),
      UserID.new(),
      Es.Event.At.now!(),
      Es.Event.ID.new()
    )
  end

  defp holder_wire, do: fixture("account/account.holder_set.json")

  defp contact_wire, do: fixture("fixture/fixture.contact_set.json")

  defp fixture(path), do: Jason.decode!(File.read!(Path.join("test/support/fixtures/events", path)))

  defp put_payload(wire, fields), do: Map.update!(wire, "payload", &Map.merge(&1, fields))
end
