defmodule Core.TestRepo do
  @moduledoc """
  Ecto-репозиторий тестов библиотеки.

  Повторяет то, что в приложении-потребителе делает его `DAO`: единственный
  Postgres-репозиторий с обёрнутым `transact`, чтобы работали хуки `AfterCommit`.
  """

  use Ecto.Repo,
    otp_app: :core,
    adapter: Ecto.Adapters.Postgres

  alias Core.Helper.AfterCommit

  defoverridable transact: 1, transact: 2

  @doc false
  @spec transact(fun() | Ecto.Multi.t(), keyword()) :: {:ok, term()} | {:error, term()}

  def transact(fun_or_multi, opts \\ []) do
    AfterCommit.wrap(fn -> super(fun_or_multi, opts) end)
  end
end
