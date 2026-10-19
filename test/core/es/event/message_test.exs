defmodule Core.Es.Event.MessageTest do
  # Реализация порта и фасад подменяются в окружении приложения — глобально, а подписчик читает
  # базу своим процессом: отсюда async: false.
  use Core.DataCase, async: false

  import Core.EsAggregateRepoContract, only: [open: 0, write!: 3]
  import ExUnit.CaptureLog

  alias Core.Config
  alias Core.Context
  alias Core.Error
  alias Core.Es
  alias Core.Es.Personal
  alias Core.Es.Personal.Destroyed
  alias Core.EsFixture.Account
  alias Core.EsFixture.UserID
  alias Core.Mq
  alias Core.MqFake
  alias Core.Outbox
  alias Core.PubSub.MqSubscriberReliable

  @holder "Иван Петров"

  defmodule RaisingCodec do
    @moduledoc false

    # Фасад тестов, чья загрузка `HolderSet` падает с открытым значением поля в аргументах кадра.
    def dump(value), do: Core.CodecFixture.Internal.dump(value)

    def load(_union, %{"payload" => %{"holder" => holder}}), do: String.to_integer(holder)
    def load(union, wire), do: Core.CodecFixture.Internal.load(union, wire)
  end

  defmodule UnopenableStore do
    @moduledoc false

    # Встроенная реализация, у которой не отвечает только `open`.
    @behaviour Core.Es.Personal.KeyStore

    alias Core.Error
    alias Core.Es.Personal.KeyStore.Pg

    require Error

    @impl true
    defdelegate seal(items), to: Pg

    @impl true
    def open(_items), do: {:error, Error.app(__MODULE__, code: :unavailable, ns: :key_store, message: "Не ответило")}

    @impl true
    defdelegate index(items), to: Pg

    @impl true
    defdelegate destroy(subject), to: Pg
  end

  describe "load/2 на теле записи outbox" do
    test "открытое значение" do
      id = holder_set!()
      holder = Account.Holder.new!(@holder)

      assert {:ok, %Account.Event.HolderSet{payload: %{holder: ^holder}}} =
               Es.Event.Message.load(Account.Event, outbox_message(id, "account.holder_set"))
    end

    test "после destroy_key/3 — событие с %Destroyed{}" do
      id = holder_set!()
      :ok = Personal.destroy_key(id, UserID.new(), Context.new())

      assert {:ok, %Account.Event.HolderSet{payload: %{holder: %Destroyed{}}}} =
               Es.Event.Message.load(Account.Event, outbox_message(id, "account.holder_set"))
    end

    test "событие без ПДн-полей и старый тег — через апкаст" do
      id = holder_set!()
      name = Account.Name.new!("Приёмка")
      message = outbox_message(id, "account.opened")

      assert {:ok, %Account.Event.Opened{payload: %{name: ^name}}} = Es.Event.Message.load(Account.Event, message)

      old =
        update_body(message, fn wire ->
          %{wire | "type" => "account.opened.v1", "payload" => %{"title" => "Приёмка"}}
        end)

      assert {:ok, %Account.Event.Opened{payload: %{name: ^name}}} = Es.Event.Message.load(Account.Event, old)
    end

    test "подменённый шифротекст — {:reject, :unreadable_personal_value}" do
      id = holder_set!()
      message = tamper(outbox_message(id, "account.holder_set"))

      assert {:reject, %Error{kind: :domain, ns: :es, code: :unreadable_personal_value, detail: detail}} =
               Es.Event.Message.load(Account.Event, message)

      assert %{field: "holder"} = detail
    end

    test "сбой хранилища ключей — {:error, _}" do
      id = holder_set!()
      put_key_store(UnopenableStore)

      assert {:error, %Error{kind: :app, code: :unavailable}} =
               Es.Event.Message.load(Account.Event, outbox_message(id, "account.holder_set"))
    end

    test "исключение апкаста или load — {:reject, :upcast_raised} без значения" do
      id = holder_set!()
      message = outbox_message(id, "account.holder_set")
      saved = Application.fetch_env!(:core, :codec)
      Application.put_env(:core, :codec, RaisingCodec)
      on_exit(fn -> Application.put_env(:core, :codec, saved) end)

      assert {:reject, %Error{kind: :app, ns: :es, code: :upcast_raised} = error} =
               Es.Event.Message.load(Account.Event, message)

      refute inspect(error) =~ @holder
    end
  end

  describe "load/2: тело, которое не разбирается" do
    setup do
      %{message: outbox_message(holder_set!(), "account.holder_set")}
    end

    test "невалидный JSON и tombstone — {:reject, :invalid_body}", %{message: message} do
      for body <- ["{не json", nil] do
        assert {:reject, %Error{kind: :domain, ns: :es, code: :invalid_body}} =
                 Es.Event.Message.load(Account.Event, %{message | body: body})
      end
    end

    test "JSON не объект — {:reject, _}", %{message: message} do
      for body <- ["42", "[]", ~s("конверт")] do
        assert {:reject, %Error{ns: :es}} = Es.Event.Message.load(Account.Event, %{message | body: body})
      end
    end

    test "ошибка load — {:reject, _}", %{message: message} do
      unknown = update_body(message, &%{&1 | "type" => "account.unknown"})

      assert {:reject, %Error{ns: :es, code: :unknown_event_type}} = Es.Event.Message.load(Account.Event, unknown)
    end

    test "конверт без event_id — {:reject, _} без расшифровки", %{message: message} do
      no_id = update_body(message, &Map.delete(&1, "event_id"))

      assert {:reject, %Error{ns: :es, code: :invalid_envelope}} = Es.Event.Message.load(Account.Event, no_id)
    end
  end

  describe "from_message: подписчика" do
    test "событие уходит в on_message" do
      id = holder_set!()
      holder = Account.Holder.new!(@holder)
      reader = MqFake.QueueReader.new([outbox_message(id, "account.holder_set")])
      test = self()

      on_message = fn event, _data, _context ->
        send(test, {:handled, event})
        :ok
      end

      sub = start_sub(reader, on_message)

      assert :processed = MqSubscriberReliable.run_once(sub)
      assert_received {:handled, %Account.Event.HolderSet{payload: %{holder: ^holder}}}
    end

    test "сбой хранилища ключей — повтор без commit" do
      id = holder_set!()
      reader = MqFake.QueueReader.new([outbox_message(id, "account.holder_set")])
      put_key_store(UnopenableStore)

      sub =
        start_sub(reader, fn _event, _data, _context -> :ok end,
          dlq_writer: MqFake.Writer,
          dlq_handle: MqFake.Writer.new()
        )

      capture_log(fn -> assert :error = MqSubscriberReliable.run_once(sub) end)

      assert MqFake.QueueReader.pending(reader) == 1
    end

    test "нечитаемое — сразу в DLQ" do
      id = holder_set!()
      reader = MqFake.QueueReader.new([tamper(outbox_message(id, "account.holder_set"))])
      dlq = MqFake.Writer.new()
      sub = start_sub(reader, fn _event, _data, _context -> :ok end, dlq_writer: MqFake.Writer, dlq_handle: dlq)

      capture_log(fn -> assert :dlq = MqSubscriberReliable.run_once(sub) end)

      assert MqFake.QueueReader.pending(reader) == 0
      assert [dead] = MqFake.Writer.published(dlq)
      assert Mq.Message.find_header(dead, Mq.HeaderKey.new!("x-dlq-reason")) == "rejected"
    end
  end

  # ---

  defp holder_set! do
    id = Account.ID.new()
    write!(Account.Repo.Pg, id, [open(), set_holder(@holder)])
    id
  end

  defp set_holder(value),
    do: %Account.Cmd.SetHolder{holder: Account.Holder.new!(value), by: UserID.new(), at: Es.Event.At.now!()}

  # Сообщение, которое опубликовала бы доставка outbox: тело — JSON записи, заголовки и ключ — её.
  defp outbox_message(id, name) do
    key = Config.codec().dump(id)

    %{payload: payload, headers: headers} =
      TestRepo.one!(
        from(r in Outbox.Repo.Pg.Schema,
          where: r.key == ^key and r.name == ^name,
          select: %{payload: r.payload, headers: r.headers}
        )
      )

    {:ok, message} =
      Mq.Message.new(Mq.Topic.new!(Account.Outbox.topic()), headers, Jason.encode!(payload), Mq.Key.new!(key))

    message
  end

  defp update_body(message, fun), do: %{message | body: Jason.encode!(fun.(Jason.decode!(message.body)))}

  # Шифротекст `holder` с изменённым последним байтом: тег GCM не сходится.
  defp tamper(message) do
    update_body(message, fn %{"payload" => %{"holder" => %{"$pd" => sealed}}} = wire ->
      ciphertext = Base.decode64!(sealed)
      head = binary_part(ciphertext, 0, byte_size(ciphertext) - 1)
      flipped = <<head::binary, Bitwise.bxor(:binary.last(ciphertext), 1)>>

      put_in(wire, ["payload", "holder"], %{"$pd" => Base.encode64(flipped)})
    end)
  end

  defp put_key_store(store) do
    Application.put_env(:core, Core.Es.Personal.KeyStore, store)
    on_exit(fn -> Application.delete_env(:core, Core.Es.Personal.KeyStore) end)
  end

  defp start_sub(reader, on_message, opts \\ []) do
    sub_opts =
      Keyword.merge(
        [
          reader_module: MqFake.QueueReader,
          reader: reader,
          from_message: &Es.Event.Message.load(Account.Event, &1),
          on_message: on_message,
          topic: Account.Outbox.topic(),
          poll_interval_ms: 60_000
        ],
        opts
      )

    {:ok, sub} = start_supervised({MqSubscriberReliable, sub_opts})
    :ok = MqSubscriberReliable.subscribe(sub, nil, Context.new())

    sub
  end
end
