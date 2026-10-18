defmodule Core.Es.Personal.DestroyKeyFailureTest do
  # Реализация порта подменяется в окружении приложения — глобально, поэтому async: false.
  use Core.DataCase, async: false

  import ExUnit.CaptureLog

  alias Core.Context
  alias Core.Error
  alias Core.Es.Personal
  alias Core.Es.Personal.Event.Codec
  alias Core.Es.Personal.SubjectID
  alias Core.Es.Store
  alias Core.EsFixture.Account
  alias Core.EsFixture.UserID

  defmodule UnavailableStore do
    @moduledoc false

    @behaviour Core.Es.Personal.KeyStore

    alias Core.Error

    require Error

    @impl true
    def seal(_items), do: {:error, unavailable()}

    @impl true
    def open(_items), do: {:error, unavailable()}

    @impl true
    def index(_items), do: {:error, unavailable()}

    @impl true
    def destroy(_subject), do: {:error, unavailable()}

    defp unavailable, do: Error.app(__MODULE__, code: :unavailable, ns: :key_store, message: "Хранилище не ответило")
  end

  setup do
    Application.put_env(:core, Core.Es.Personal.KeyStore, UnavailableStore)
    on_exit(fn -> Application.delete_env(:core, Core.Es.Personal.KeyStore) end)
  end

  test "сбой порта — ошибка вызывающему без события и без лога" do
    subject = Account.ID.new()

    log =
      capture_log(fn ->
        assert {:error, %Error{kind: :app, ns: :key_store, code: :unavailable}} =
                 Personal.destroy_key(subject, UserID.new(), Context.new())
      end)

    assert log == ""
    assert Store.Test.events!(Codec, SubjectID.new!(Account.ID.value(subject))) == []
  end
end
