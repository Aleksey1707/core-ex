defmodule Core.Es.Personal.KeyReservationFailureTest do
  # Реализация порта подменяется в окружении приложения — глобально, поэтому async: false.
  use Core.DataCase, async: false

  import Core.EsAggregateRepoContract, only: [execute!: 2, open: 1, stream_tags: 1, write!: 3]

  alias Core.Config
  alias Core.Context
  alias Core.Error
  alias Core.Es
  alias Core.EsFixture.Account
  alias Core.EsFixture.UserID
  alias Core.Exc

  require Config

  @repo Config.repo!(Account.KeyedRepo)

  defmodule IndexUnavailableStore do
    @moduledoc false

    @behaviour Core.Es.Personal.KeyStore

    alias Core.Error
    alias Core.Es.Personal.KeyStore.Pg

    require Error

    @impl true
    def seal(items), do: Pg.seal(items)

    @impl true
    def open(items), do: Pg.open(items)

    @impl true
    def index(_items) do
      send(self(), :index)
      {:error, Error.app(__MODULE__, code: :unavailable, ns: :key_store, message: "Хранилище не ответило")}
    end

    @impl true
    def destroy(subject), do: Pg.destroy(subject)
  end

  setup do
    Application.put_env(:core, Core.Es.Personal.KeyStore, IndexUnavailableStore)
    on_exit(fn -> Application.delete_env(:core, Core.Es.Personal.KeyStore) end)
  end

  test "отказ index откатывает append, Es.Transact его не повторяет" do
    id = Account.ID.new()
    state = write!(@repo, id, [open(unique_name())])
    {events, _state} = execute!(state, set_holder("Владелец #{System.unique_integer([:positive])}"))

    assert {{:error, %Error{kind: :app, ns: :key_store, code: :unavailable}}, 0} =
             Es.Transact.run_counted(fn -> @repo.append(events, Context.new()) end)

    assert_received :index
    refute_received :index
    assert [_opened] = stream_tags(id)
  end

  test "отказ index в find/2 — Core.Exc" do
    assert_raise Exc, fn -> Account.HolderKey.find(Account.Holder.new!("Владелец"), Context.new()) end
  end

  defp unique_name, do: "Счёт #{System.unique_integer([:positive])}"

  defp set_holder(value),
    do: %Account.Cmd.SetHolder{holder: Account.Holder.new!(value), by: UserID.new(), at: Es.Event.At.now!()}
end
