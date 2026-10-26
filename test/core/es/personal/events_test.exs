defmodule Core.Es.Personal.EventsTest do
  use Core.DataCase, async: true

  import Core.EsAggregateRepoContract, only: [execute!: 2, open: 0, write!: 3]
  import Ecto.Query

  alias Core.Config
  alias Core.Context
  alias Core.DerivedFixture
  alias Core.DerivedFixture.Event.Contacted
  alias Core.Error
  alias Core.Es
  alias Core.Es.Personal
  alias Core.Es.Personal.Destroyed
  alias Core.EsFixture.Account
  alias Core.EsFixture.UserID
  alias Core.EventFixture
  alias Core.EventFixture.ActorID
  alias Core.EventFixture.AggID
  alias Core.EventFixture.PersonID
  alias Core.Outbox
  alias Core.Pagination
  alias Core.StateStoredFixture
  alias Core.Version

  @holder "Иван Петров"
  @contact "+7 900 000-00-00"
  @note "Звонить после обеда"
  @state_stored StateStoredFixture.Repo.Pg

  defmodule RaisingCodec do
    @moduledoc false

    # Фасад, чья загрузка ПДн-значения `Holder` падает с открытым значением в аргументах кадра.
    def dump(value), do: Config.codec().dump(value)

    def load(Core.EsFixture.Account.Holder, holder) when is_binary(holder), do: String.to_integer(holder)
    def load(mod, raw), do: Config.codec().load(mod, raw)
  end

  defmodule RaisingRepo do
    @moduledoc false

    use Core.Es.Aggregate.Repo.Pg,
      behaviour: Core.EsFixture.Account.Repo,
      errors: Core.EsFixture.Account.Errors,
      outbox: Core.EsFixture.Account.Outbox,
      codec: Core.Es.Personal.EventsTest.RaisingCodec
  end

  describe "счёт: запись" do
    test "в es_events и outbox — $pd без открытого текста" do
      id = Account.ID.new()
      write!(Account.Repo.Pg, id, [open(), set_holder(@holder)])

      assert %{"holder" => %{"$pd" => sealed}} = stored_payload("account", id, "account.holder_set")
      assert %{"payload" => %{"holder" => %{"$pd" => outboxed}}} = outbox_payload(id, "account.holder_set")
      assert [sealed, outboxed] |> Enum.all?(&is_binary/1)
      refute inspect([sealed, outboxed]) =~ @holder
    end

    test "событие без ПДн-полей пишется как раньше" do
      id = Account.ID.new()
      write!(Account.Repo.Pg, id, [open()])

      assert stored_payload("account", id, "account.opened") == %{"name" => "Приёмка"}
    end
  end

  describe "счёт: чтение" do
    test "get, page_stream и events! — открытое значение" do
      id = Account.ID.new()
      write!(Account.Repo.Pg, id, [open(), set_holder(@holder)])
      holder = Account.Holder.new!(@holder)

      assert {:ok, %Account{holder: ^holder}} = Account.Repo.Pg.get(id, :current, Context.new())
      assert {:ok, %Pagination.Result{items: [_opened, page_event]}} = page(id)
      assert %Account.Event.HolderSet{payload: %{holder: ^holder}} = page_event
      assert [_opened, %Account.Event.HolderSet{payload: %{holder: ^holder}}] = events!(id)
    end

    test "после destroy_key/3 — %Destroyed{} на всех путях" do
      id = Account.ID.new()
      write!(Account.Repo.Pg, id, [open(), set_holder(@holder)])

      assert :ok = Personal.destroy_key(id, UserID.new(), Context.new())

      assert {:ok, %Account{holder: %Destroyed{}}} = Account.Repo.Pg.get(id, :current, Context.new())
      assert {:ok, %Pagination.Result{items: [_opened, %{payload: %{holder: %Destroyed{}}}]}} = page(id)
      assert [_opened, %{payload: %{holder: %Destroyed{}}}] = events!(id)
    end

    test "строка, записанная открытой до разметки поля, читается" do
      id = Account.ID.new()
      write!(Account.Repo.Pg, id, [open()])
      insert_open_holder!(id, 2, @holder)

      assert {:ok, %Account{holder: holder}} = Account.Repo.Pg.get(id, :current, Context.new())
      assert holder == Account.Holder.new!(@holder)
    end

    test "подменённый шифротекст — :unreadable_personal_value: get — Core.Exc, страница — ошибка" do
      id = Account.ID.new()
      write!(Account.Repo.Pg, id, [open(), set_holder(@holder)])
      tamper!(id, "account.holder_set", "holder")

      error = assert_raise Core.Exc, fn -> Account.Repo.Pg.get(id, :current, Context.new()) end
      assert %Error{kind: :domain, ns: :es, code: :unreadable_personal_value, detail: detail} = error.error
      assert detail == %{event_id: event_id(id, "account.holder_set"), field: "holder"}

      assert {:error, %Error{code: :unreadable_personal_value}} = page(id)
    end

    test "не base64 в $pd — :unreadable_personal_value" do
      id = Account.ID.new()
      write!(Account.Repo.Pg, id, [open()])
      insert_open_holder!(id, 2, %{"$pd" => "не base64"})

      assert {:error, %Error{code: :unreadable_personal_value}} = page(id)
    end
  end

  describe "счёт: исключение загрузки" do
    test "на строке с расшифрованным $pd — :upcast_raised без значения и аргументов кадров" do
      id = Account.ID.new()
      write!(Account.Repo.Pg, id, [open(), set_holder(@holder)])

      assert %Core.Exc{error: %Error{kind: :app, ns: :es, code: :upcast_raised, detail: detail} = error} =
               catch_error(RaisingRepo.get(id, :current, Context.new()))

      assert %{event_id: event_id, exception: ArgumentError, module: :erlang, stacktrace: stacktrace} = detail
      assert event_id == event_id(id, "account.holder_set")
      assert Enum.all?(stacktrace, fn {_module, _fun, arity, _location} -> is_integer(arity) end)
      refute inspect(error) =~ @holder
    end

    test "на строке без $pd — исключение как раньше" do
      id = Account.ID.new()
      write!(Account.Repo.Pg, id, [open()])
      insert_open_holder!(id, 2, @holder)

      assert_raise ArgumentError, fn -> RaisingRepo.get(id, :current, Context.new()) end
    end
  end

  describe "счёт: отказы записи" do
    test "после destroy_key/3 — :subject_destroyed, запись откатывается, повтора нет" do
      id = Account.ID.new()
      state = write!(Account.Repo.Pg, id, [open(), set_holder(@holder)])
      :ok = Personal.destroy_key(id, UserID.new(), Context.new())

      {result, attempts} = counted(fn -> append_holder(state, "Пётр Иванов") end)

      assert {:error, %Error{kind: :domain, ns: :key_store, code: :subject_destroyed}} = result
      assert attempts == 1
      assert [_opened, _holder_set] = events!(id)
    end

    test "субъект без ключа после destroy_key/3 — :subject_destroyed" do
      id = Account.ID.new()
      state = write!(Account.Repo.Pg, id, [open()])
      :ok = Personal.destroy_key(id, UserID.new(), Context.new())

      assert {:error, %Error{code: :subject_destroyed}} = append_holder(state, @holder)
      assert [_opened] = events!(id)
    end

    test "уничтоженное значение в новом событии — ArgumentError с полем и event_id, без значения" do
      id = Account.ID.new()
      write!(Account.Repo.Pg, id, [open()])
      {:ok, state} = Account.Repo.Pg.get(id, :current, Context.new())
      {[event], _state} = execute!(state, set_holder(@holder))
      destroyed = Personal.Test.destroyed(event)

      error =
        assert_raise ArgumentError, fn -> Es.Store.append(Account.Event.Codec, [destroyed], Context.new(), & &1) end

      assert error.message =~ "event_id=#{Es.Event.ID.value(event.id)} field=holder"
    end

    test "запись outbox с маркером мимо flush падает на маркере, без значения" do
      id = Account.ID.new()
      {[_opened, event], _state} = execute_all(id, [open(), set_holder(@holder)])
      {:ok, record} = Account.Outbox.from_event(event)

      error = catch_error(Config.outbox_repo().append([record], Context.new()))

      assert %Protocol.UndefinedError{} = error
      refute Exception.message(error) =~ @holder
    end
  end

  describe "state-stored: два субъекта в событии" do
    test "уничтожен ключ лица — контакт %Destroyed{}, заметка агрегата читается" do
      id = AggID.new()
      person = PersonID.new()
      contact_set = EventFixture.in_stream(EventFixture.contact_set(person, @contact, @note), id, 1)

      assert {:ok, _written} = @state_stored.insert(entity(id, [contact_set]), Context.new())

      assert %{"contact" => %{"$pd" => _}, "note" => %{"$pd" => _}} =
               stored_payload("fixture", id, "fixture.contact_set")

      assert %{"payload" => %{"contact" => %{"$pd" => _}, "note" => %{"$pd" => _}}} =
               outbox_payload(id, "fixture.contact_set")

      contact = EventFixture.Contact.new!(@contact)
      note = EventFixture.Note.new!(@note)
      assert [%{payload: %{contact: ^contact, note: ^note}}] = Es.Store.Test.events!(EventFixture.Event.Codec, id)

      assert :ok = Personal.destroy_key(person, UserID.new(), Context.new())

      assert [%{payload: %{contact: %Destroyed{}, note: ^note, person_id: ^person}}] =
               Es.Store.Test.events!(EventFixture.Event.Codec, id)
    end

    test "запись ПДн уничтоженного субъекта — :subject_destroyed, строка не записана" do
      id = AggID.new()
      person = PersonID.new()
      :ok = Personal.destroy_key(person, UserID.new(), Context.new())
      contact_set = EventFixture.in_stream(EventFixture.contact_set(person, @contact, @note), id, 1)

      assert {:error, %Error{code: :subject_destroyed}} = @state_stored.insert(entity(id, [contact_set]), Context.new())
      assert {:error, %Error{code: :not_found}} = @state_stored.get(id, :current, Context.new())
    end
  end

  describe "set: и map: с subject:" do
    test "шифротекст — поле целиком; чтение — открытое значение, после destroy_key/3 — %Destroyed{}" do
      id = AggID.new()
      contacts = MapSet.new([@contact, "+7 900 000-00-01"], &EventFixture.Contact.new!/1)
      by_kind = %{"дом" => EventFixture.Contact.new!(@contact)}

      event =
        Contacted.new(Contacted.Payload.new(contacts, by_kind), id, Version.new(), ActorID.new(), Es.Event.At.now!())

      :ok = Es.Store.append(DerivedFixture.Event.Codec, [event], Context.new(), & &1)

      assert %{"contacts" => %{"$pd" => sealed}, "contact_by_kind" => %{"$pd" => sealed_by_kind}} =
               stored_payload("derived", id, "derived.contacted")

      assert is_binary(sealed) and is_binary(sealed_by_kind)
      refute Base.decode64!(sealed) =~ @contact
      refute Base.decode64!(sealed_by_kind) =~ @contact

      assert [%Contacted{payload: %{contacts: ^contacts, contact_by_kind: ^by_kind}}] =
               Es.Store.Test.events!(DerivedFixture.Event.Codec, id)

      assert :ok = Personal.destroy_key(id, UserID.new(), Context.new())

      assert [%Contacted{payload: %{contacts: %Destroyed{}, contact_by_kind: %Destroyed{}}}] =
               Es.Store.Test.events!(DerivedFixture.Event.Codec, id)
    end
  end

  # ---

  defp set_holder(value),
    do: %Account.Cmd.SetHolder{holder: Account.Holder.new!(value), by: UserID.new(), at: Es.Event.At.now!()}

  # Решение — от состояния до уничтожения ключа: после него агрегат сам отказал бы в новом владельце.
  defp append_holder(state, value) do
    {events, _state} = execute!(state, set_holder(value))

    Es.Transact.run(fn ->
      send(self(), :attempt)
      Account.Repo.Pg.append(events, Context.new())
    end)
  end

  defp counted(fun) do
    result = fun.()
    {result, count_attempts(0)}
  end

  defp count_attempts(count) do
    receive do
      :attempt -> count_attempts(count + 1)
    after
      0 -> count
    end
  end

  defp execute_all(id, commands) do
    Enum.reduce(commands, {[], %Account{id: id}}, fn command, {events, state} ->
      {new, state} = execute!(state, command)
      {events ++ new, state}
    end)
  end

  defp page(id),
    do: Account.Repo.Pg.page_stream(id, Pagination.Limit.new!(10), Pagination.Offset.new!(0), Context.new())

  defp events!(id), do: Es.Store.Test.events!(Account.Event.Codec, id)

  defp entity(id, events) do
    %StateStoredFixture.Entity{
      id: id,
      version: Version.new!(1),
      name: "Приёмка",
      children: %{},
      events: Es.Events.new(events)
    }
  end

  defp stored_payload(type, id, tag), do: TestRepo.one!(select(stored(type, id, tag), [e], e.payload))

  defp event_id(id, tag), do: TestRepo.one!(select(stored("account", id, tag), [e], type(e.event_id, :binary_id)))

  defp stored(type, id, tag) do
    db_id = Config.codec().dump(id)

    from(e in "es_events",
      where: e.aggregate_type == ^type and e.aggregate_id == type(^db_id, :binary_id) and e.tag == ^tag
    )
  end

  defp outbox_payload(id, name) do
    key = Config.codec().dump(id)
    TestRepo.one!(from(r in Outbox.Repo.Pg.Schema, where: r.key == ^key and r.name == ^name, select: r.payload))
  end

  # Шифротекст с изменённым последним байтом: тег GCM не сходится.
  defp tamper!(id, tag, field) do
    %{^field => %{"$pd" => sealed}} = payload = stored_payload("account", id, tag)
    ciphertext = Base.decode64!(sealed)
    head = binary_part(ciphertext, 0, byte_size(ciphertext) - 1)
    last = :binary.last(ciphertext)
    tampered = Map.put(payload, field, %{"$pd" => Base.encode64(<<head::binary, Bitwise.bxor(last, 1)>>)})

    {1, _} = TestRepo.update_all(stored("account", id, tag), set: [payload: tampered])
    :ok
  end

  defp insert_open_holder!(id, version, holder) do
    row = %{
      aggregate_type: "account",
      aggregate_id: Config.codec().dump(id),
      aggregate_version: version,
      event_id: Es.Event.ID.value(Es.Event.ID.new()),
      tag: "account.holder_set",
      payload: %{"holder" => holder},
      by_id: UserID.value(UserID.new()),
      at: DateTime.utc_now(:second)
    }

    {1, nil} = TestRepo.insert_all(Es.Store.Schema, [row])
    :ok
  end
end
