defmodule Core.Helper.Savepoint do
  @moduledoc """
  Выполнение блока в SAVEPOINT внутри текущей транзакции Ecto.

  Успех (`:ok` / `{:ok, _}`) — RELEASE; `{:error, _}` или исключение —
  ROLLBACK TO SAVEPOINT без аборта внешней транзакции.
  """

  require Logger

  @type result :: :ok | {:ok, term()} | {:error, term()}

  @doc """
  Выполняет `fun` внутри SAVEPOINT на соединении `repo`.
  """
  @spec run(Ecto.Repo.t(), (-> result())) :: result()

  def run(repo, fun) when is_function(fun, 0) do
    name = "sp_#{System.unique_integer([:positive, :monotonic])}"
    savepoint(repo, name)

    try do
      case fun.() do
        :ok = ok ->
          release(repo, name)
          ok

        {:ok, _} = ok ->
          release(repo, name)
          ok

        {:error, _} = error ->
          rollback_to(repo, name)
          error
      end
    rescue
      e ->
        stack = __STACKTRACE__
        safe_rollback_to(repo, name)
        reraise e, stack
    end
  end

  # ---

  # Имя savepoint'а — "sp_<System.unique_integer>", внешний ввод сюда не попадает,
  # а имя savepoint'а по природе команды не параметризуется в SQL.
  # sobelow_skip ["SQL.Query"]
  defp savepoint(repo, name),
    do: Ecto.Adapters.SQL.query!(repo, "SAVEPOINT #{name}")

  # sobelow_skip ["SQL.Query"]
  defp release(repo, name),
    do: Ecto.Adapters.SQL.query!(repo, "RELEASE SAVEPOINT #{name}")

  # sobelow_skip ["SQL.Query"]
  defp rollback_to(repo, name),
    do: Ecto.Adapters.SQL.query!(repo, "ROLLBACK TO SAVEPOINT #{name}")

  defp safe_rollback_to(repo, name) do
    rollback_to(repo, name)
  rescue
    rollback_error ->
      Logger.error(
        "Не удалось ROLLBACK TO SAVEPOINT #{name}: #{Exception.message(rollback_error)}"
      )

      :ok
  end
end
