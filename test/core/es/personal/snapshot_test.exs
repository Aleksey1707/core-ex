defmodule Core.Es.Personal.SnapshotTest do
  # Реализация порта подменяется в окружении приложения — глобально: отсюда async: false.
  use Core.DataCase, async: false

  import Core.EsAggregateRepoContract, only: [dump: 1, freeze: 0, open: 0, write!: 3]
  import ExUnit.CaptureLog

  alias Core.Config
  alias Core.Context
  alias Core.Error
  alias Core.Es
  alias Core.Es.Aggregate.Repo.Pg.Snapshot
  alias Core.Es.Personal
  alias Core.Es.Personal.Destroyed
  alias Core.EsFixture.Account
  alias Core.EsFixture.UserID
  alias Core.Telemetry

  @holder "Иван Петров"
  @repo Account.Repo.Pg.Snapshotted

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

  describe "запись" do
    test "в es_snapshots — шифротекст без открытого текста; чтение от него — hit" do
      id = Account.ID.new()
      state = write!(@repo, id, [open(), set_holder(@holder)])
      assert {:ok, ^state} = @repo.get(id, :current, Context.new())

      stored = snapshot!(id).state
      assert :binary.match(stored, @holder) == :nomatch
      assert_raise ArgumentError, fn -> :erlang.binary_to_term(stored, [:safe]) end

      attach_telemetry()
      assert {:ok, ^state} = @repo.get(id, :current, Context.new())
      assert_received {:telemetry, [:core, :es, :aggregate, :fold], %{events: 0}, %{snapshot: :hit}}
    end

    test "маркер шифрованного снапшота — свой" do
      cfg = %{aggregate: Account, event_codec: Account.Event.Codec, snapshot: %{version: 1, sealed: true}}

      refute Snapshot.marker(cfg) == Snapshot.marker(put_in(cfg.snapshot.sealed, false))
    end

    test "ключ уничтожен, а чтение уничтоженного не видело — снапшот не пишется, debug" do
      id = Account.ID.new()
      state = write!(@repo, id, [open(), freeze()])
      assert :ok = Personal.destroy_key(id, UserID.new(), Context.new())

      log = capture_debug(fn -> assert {:ok, ^state} = @repo.get(id, :current, Context.new()) end)

      assert log =~ "снапшот агрегата не записан: ключ субъекта уничтожен: type=account aggregate_id=#{dump(id)}"
      refute log =~ "[warning]"
      assert snapshot!(id) == nil
    end

    test "get_many — снапшот уничтоженного субъекта не пишется, остальные пишутся" do
      [destroyed, alive] = [Account.ID.new(), Account.ID.new()]
      Enum.each([destroyed, alive], &write!(@repo, &1, [open(), freeze()]))
      assert :ok = Personal.destroy_key(destroyed, UserID.new(), Context.new())

      log =
        capture_debug(fn ->
          assert {:ok, [_, _]} = @repo.get_many([{destroyed, :current}, {alive, :current}], Context.new())
        end)

      assert log =~ "ключ субъекта уничтожен: type=account aggregate_id=#{dump(destroyed)}"
      assert snapshot!(destroyed) == nil
      assert %Snapshot.Schema{aggregate_version: 2} = snapshot!(alive)
    end

    test "чтение видело уничтоженное значение — запись не пытается" do
      id = Account.ID.new()
      write!(@repo, id, [open(), set_holder(@holder)])
      assert :ok = Personal.destroy_key(id, UserID.new(), Context.new())
      attach_telemetry()

      assert {:ok, %Account{holder: %Destroyed{}}} = @repo.get(id, :current, Context.new())

      refute_received {:telemetry, [:core, :es, :personal, :call], _measurements, %{op: :seal}}
      refute_received {:telemetry, [:core, :es, :snapshot, :write], _measurements, _metadata}
      assert snapshot!(id) == nil
    end

    test "сбой порта — warning, снапшот не записан" do
      id = Account.ID.new()
      state = write!(@repo, id, [open(), freeze()])
      put_key_store(UnsealableStore)
      attach_telemetry()

      log = capture_log(fn -> assert {:ok, ^state} = @repo.get(id, :current, Context.new()) end)

      assert log =~ "снапшоты агрегата не записаны: type=account rows=1"
      assert snapshot!(id) == nil
      assert_received {:telemetry, [:core, :es, :snapshot, :write], %{rows: 0}, %{result: :error}}
    end
  end

  describe "чтение" do
    test "снапшот и ПДн-значения хвоста — одним вызовом open" do
      id = Account.ID.new()
      write!(@repo, id, [open(), set_holder(@holder)])
      assert {:ok, _state} = @repo.get(id, :current, Context.new())
      write!(@repo, id, [set_holder("Пётр Иванов")])
      attach_telemetry()

      assert {:ok, %Account{holder: holder}} = @repo.get(id, :current, Context.new())

      assert holder == Account.Holder.new!("Пётр Иванов")
      assert_received {:telemetry, [:core, :es, :aggregate, :fold], %{events: 1}, %{snapshot: :hit}}
      assert_received {:telemetry, [:core, :es, :personal, :call], _measurements, %{op: :open}}
      refute_received {:telemetry, [:core, :es, :personal, :call], _measurements, %{op: :open}}
    end

    test "после destroy_key/3 — полная свёртка и ни одного нового снапшота" do
      id = Account.ID.new()
      write!(@repo, id, [open(), set_holder(@holder)])
      assert {:ok, _state} = @repo.get(id, :current, Context.new())
      before = snapshot!(id)
      assert :ok = Personal.destroy_key(id, UserID.new(), Context.new())
      attach_telemetry()

      log =
        capture_debug(fn ->
          assert {:ok, %Account{holder: %Destroyed{}}} = @repo.get(id, :current, Context.new())
          write!(@repo, id, [freeze()])
          assert {:ok, %Account{status: :frozen, holder: %Destroyed{}}} = @repo.get(id, :current, Context.new())
        end)

      assert log =~
               "снапшот агрегата отвергнут: type=account aggregate_id=#{dump(id)} aggregate_version=2 reason=destroyed"

      refute log =~ "[warning]"
      assert_received {:telemetry, [:core, :es, :aggregate, :fold], %{events: 2}, %{snapshot: :rejected}}
      refute_received {:telemetry, [:core, :es, :snapshot, :write], _measurements, _metadata}
      assert snapshot!(id) == before
    end

    test "подменённый шифротекст — warning и верное состояние" do
      id = Account.ID.new()
      state = write!(@repo, id, [open(), set_holder(@holder)])
      assert {:ok, ^state} = @repo.get(id, :current, Context.new())
      update_snapshot!(id, state: flip_last(snapshot!(id).state))

      log = capture_log(fn -> assert {:ok, ^state} = @repo.get(id, :current, Context.new()) end)

      assert log =~ "снапшот агрегата отвергнут: type=account aggregate_id=#{dump(id)}"
      assert log =~ "reason=unreadable"
      refute log =~ @holder
    end

    test "версия строки не та, под которой запечатан, — AAD не сходится" do
      id = Account.ID.new()
      state = write!(@repo, id, [open(), set_holder(@holder)])
      assert {:ok, ^state} = @repo.get(id, :current, Context.new())
      update_snapshot!(id, aggregate_version: 1)

      log = capture_log(fn -> assert {:ok, ^state} = @repo.get(id, :current, Context.new()) end)

      assert log =~ "aggregate_version=1 reason=unreadable"
    end

    test "сбой порта — ошибка вызывающему" do
      id = Account.ID.new()
      write!(@repo, id, [open(), set_holder(@holder)])
      assert {:ok, _state} = @repo.get(id, :current, Context.new())
      put_key_store(UnopenableStore)

      assert {:error, %Error{kind: :app, code: :unavailable}} = @repo.get(id, :current, Context.new())
    end
  end

  def handle_telemetry(event, measurements, metadata, test) do
    if self() == test, do: send(test, {:telemetry, event, measurements, metadata})
  end

  defp attach_telemetry do
    handler = {__MODULE__, make_ref()}

    events = [
      Telemetry.event([:es, :aggregate, :fold]),
      Telemetry.event([:es, :snapshot, :write]),
      Telemetry.event([:es, :personal, :call])
    ]

    :ok = :telemetry.attach_many(handler, events, &__MODULE__.handle_telemetry/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp put_key_store(impl) do
    Application.put_env(:core, Core.Es.Personal.KeyStore, impl)
    on_exit(fn -> Application.delete_env(:core, Core.Es.Personal.KeyStore) end)
  end

  defp set_holder(value),
    do: %Account.Cmd.SetHolder{holder: Account.Holder.new!(value), by: UserID.new(), at: Es.Event.At.now!()}

  defp snapshot!(id),
    do: Config.dao().get_by(Snapshot.Schema, aggregate_type: "account", aggregate_id: dump(id))

  defp update_snapshot!(id, set) do
    {1, nil} =
      from(sn in Snapshot.Schema, where: sn.aggregate_type == "account" and sn.aggregate_id == ^dump(id))
      |> Config.dao().update_all(set: set)

    :ok
  end

  defp flip_last(binary) do
    head = binary_part(binary, 0, byte_size(binary) - 1)
    <<head::binary, Bitwise.bxor(:binary.last(binary), 1)>>
  end

  # Уровень модуля глобален, а тест-модуль идёт без async.
  defp capture_debug(fun) do
    Logger.put_module_level(Snapshot, :debug)

    try do
      capture_log(fun)
    after
      Logger.delete_module_level(Snapshot)
    end
  end
end
