defmodule Core.Es.Personal.EventsProjectionTest do
  # Пачка проекции читает события по глобальной позиции, а реализация порта подменяется в окружении
  # приложения — глобально: отсюда async: false.
  use Core.DataCase, async: false

  import Core.EsAggregateRepoContract, only: [execute!: 2, open: 0, write!: 3]
  import Ecto.Query

  alias Core.Config
  alias Core.Context
  alias Core.Error
  alias Core.Es
  alias Core.Es.Personal
  alias Core.Es.Personal.Destroyed
  alias Core.EsFixture.Account
  alias Core.EsFixture.UserID
  alias Core.Pagination

  @holder "Иван Петров"

  defmodule Holders do
    @moduledoc false

    # Проекция без таблицы: загруженное событие уходит процессу пачки — процессу теста.
    use Core.Es.Projection,
      name: "personal_events_holders",
      events: [Core.EsFixture.Account.Event.HolderSet]

    @impl true
    def project(event) do
      send(self(), {:projected, event})
      :ok
    end

    @impl true
    def clear, do: :ok
  end

  defmodule Openings do
    @moduledoc false

    use Core.Es.Projection,
      name: "personal_events_openings",
      events: [Core.EsFixture.Account.Event.Opened]

    @impl true
    def project(_event), do: :ok

    @impl true
    def clear, do: :ok
  end

  defmodule RaisingCodec do
    @moduledoc false

    # Фасад тестов, чья загрузка `HolderSet` падает с открытым значением поля в аргументах кадра.
    def dump(value), do: Core.CodecFixture.Internal.dump(value)

    def load(_union, %{"payload" => %{"holder" => holder}}), do: String.to_integer(holder)
    def load(union, wire), do: Core.CodecFixture.Internal.load(union, wire)
  end

  defmodule RaisingHolders do
    @moduledoc false

    use Core.Es.Projection,
      name: "personal_events_raising_holders",
      events: [Core.EsFixture.Account.Event.HolderSet],
      codec: Core.Es.Personal.EventsProjectionTest.RaisingCodec

    @impl true
    def project(_event), do: :ok

    @impl true
    def clear, do: :ok
  end

  defmodule UnsealableStore do
    @moduledoc false

    # Встроенная реализация, у которой не отвечает только `seal`.
    @behaviour Core.Es.Personal.KeyStore

    alias Core.Error
    alias Core.Es.Personal.KeyStore.Pg

    require Error

    @impl true
    def seal(_items), do: {:error, Error.app(__MODULE__, code: :unavailable, ns: :key_store, message: "Не ответило")}

    @impl true
    defdelegate open(items), to: Pg

    @impl true
    defdelegate index(items), to: Pg

    @impl true
    defdelegate destroy(subject), to: Pg
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

  describe "пачка проекции" do
    test "открытое значение, после destroy_key/3 — %Destroyed{}" do
      id = Account.ID.new()
      write!(Account.Repo.Pg, id, [open(), set_holder(@holder)])
      holder = Account.Holder.new!(@holder)

      assert :ok = Es.Projection.Test.run_until_idle(Holders)
      assert_received {:projected, %Account.Event.HolderSet{payload: %{holder: ^holder}}}

      :ok = Personal.destroy_key(id, UserID.new(), Context.new())
      reset_checkpoint!("personal_events_holders")

      assert :ok = Es.Projection.Test.run_until_idle(Holders)
      assert_received {:projected, %Account.Event.HolderSet{payload: %{holder: %Destroyed{}}}}
    end

    test "подменённый шифротекст — :unreadable_personal_value, чекпоинт стоит" do
      id = Account.ID.new()
      write!(Account.Repo.Pg, id, [open(), set_holder(@holder)])
      tamper!(id)

      assert {:error, %Error{code: :unreadable_personal_value}} = Es.Projection.Test.run_until_idle(Holders)
      refute_received {:projected, _event}
    end

    test "тег, не объявленный проекцией, не расшифровывается" do
      id = Account.ID.new()
      write!(Account.Repo.Pg, id, [open(), set_holder(@holder)])
      tamper!(id)
      attach_open()

      assert :ok = Es.Projection.Test.run_until_idle(Openings)
      refute_received {:telemetry_open, _metadata}
    end
  end

  describe "исключение загрузки на строке с расшифрованным $pd" do
    setup do
      id = Account.ID.new()
      write!(Account.Repo.Pg, id, [open(), set_holder(@holder)])

      Application.put_env(:core, :codec, RaisingCodec)
      on_exit(fn -> Application.put_env(:core, :codec, Core.CodecFixture.Internal) end)

      %{id: id}
    end

    test "страница — :upcast_raised без значения", %{id: id} do
      assert {:error, %Error{code: :upcast_raised} = error} =
               Account.Repo.Pg.page_stream(id, Pagination.Limit.new!(10), Pagination.Offset.new!(0), Context.new())

      refute inspect(error) =~ @holder
    end

    test "пачка проекции — :upcast_raised без значения" do
      assert {:error, %Error{code: :upcast_raised} = error} = Es.Projection.Test.run_until_idle(RaisingHolders)
      refute inspect(error) =~ @holder
    end
  end

  describe "сбой хранилища ключей на записи" do
    test "ошибка вызывающему без повтора, событие не записано" do
      id = Account.ID.new()
      state = write!(Account.Repo.Pg, id, [open()])
      {events, _state} = execute!(state, set_holder(@holder))
      Application.put_env(:core, Core.Es.Personal.KeyStore, UnsealableStore)
      on_exit(fn -> Application.delete_env(:core, Core.Es.Personal.KeyStore) end)

      result =
        Es.Transact.run(fn ->
          send(self(), :attempt)
          Account.Repo.Pg.append(events, Context.new())
        end)

      assert {:error, %Error{kind: :app, code: :unavailable}} = result
      assert_received :attempt
      refute_received :attempt
      assert [_opened] = Es.Store.Test.events!(Account.Event.Codec, id)
    end
  end

  describe "сбой хранилища ключей на чтении" do
    setup do
      id = Account.ID.new()
      write!(Account.Repo.Pg, id, [open(), set_holder(@holder)])

      Application.put_env(:core, Core.Es.Personal.KeyStore, UnopenableStore)
      on_exit(fn -> Application.delete_env(:core, Core.Es.Personal.KeyStore) end)

      %{id: id}
    end

    test "свёртка и страница отдают ошибку вызывающему", %{id: id} do
      assert {:error, %Error{kind: :app, code: :unavailable}} = Account.Repo.Pg.get(id, :current, Context.new())

      assert {:error, %Error{code: :unavailable}} =
               Account.Repo.Pg.page_stream(id, Pagination.Limit.new!(10), Pagination.Offset.new!(0), Context.new())
    end

    test "пачка проекции — ошибка, событие не спроецировано" do
      assert {:error, %Error{code: :unavailable}} = Es.Projection.Test.run_until_idle(Holders)
      refute_received {:projected, _event}
    end
  end

  # ---

  defp set_holder(value),
    do: %Account.Cmd.SetHolder{holder: Account.Holder.new!(value), by: UserID.new(), at: Es.Event.At.now!()}

  defp reset_checkpoint!(name) do
    {1, _} = TestRepo.update_all(from(c in "es_checkpoints", where: c.name == ^name), set: [xid: nil, number: nil])
    :ok
  end

  defp attach_open do
    test = self()
    handler = "personal-events-open-#{inspect(test)}"

    :telemetry.attach(
      handler,
      Core.Telemetry.event([:es, :personal, :open]),
      fn _event, _measurements, metadata, _config -> send(test, {:telemetry_open, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  # Шифротекст `HolderSet` с изменённым последним байтом: тег GCM не сходится.
  defp tamper!(id) do
    db_id = Config.codec().dump(id)

    query =
      from(e in "es_events",
        where: e.aggregate_type == "account" and e.aggregate_id == type(^db_id, :binary_id),
        where: e.tag == "account.holder_set"
      )

    %{"holder" => %{"$pd" => sealed}} = TestRepo.one!(select(query, [e], e.payload))
    ciphertext = Base.decode64!(sealed)

    flipped =
      <<binary_part(ciphertext, 0, byte_size(ciphertext) - 1)::binary, Bitwise.bxor(:binary.last(ciphertext), 1)>>

    {1, _} = TestRepo.update_all(query, set: [payload: %{"holder" => %{"$pd" => Base.encode64(flipped)}}])
    :ok
  end
end
