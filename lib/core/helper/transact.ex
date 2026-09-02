defmodule Core.Helper.Transact do
  @moduledoc """
  Обёртка над `c:Ecto.Repo.transact/2` для CQS-команд.

  Callback может вернуть `:ok | {:ok, term()} | {:error, term()}`.
  Голое `:ok` адаптируется к контракту Ecto и снаружи снова становится `:ok`.
  """

  alias Core.Config

  require Logger

  @doc """
  Выполняет `fun` в транзакции `repo`.
  """
  @spec run(Ecto.Repo.t(), (-> a), keyword()) :: a when a: var

  def run(repo, fun, opts \\ []) when is_function(fun, 0) and is_list(opts) do
    case repo.transact(fn -> to_ecto(fun.()) end, opts) do
      {:ok, :none} -> :ok
      other -> other
    end
  end

  @doc """
  Залогировать ошибку, если внешний эффект выполняется внутри DB-транзакции.

  Вызывается на границах, которые ходят по сети (HTTP-клиенты интеграторов, publish в брокер).
  Внутри транзакции такой вызов удерживает соединение из пула на всё время сетевого запроса
  и растягивает блокировки строк — см. `.claude/rules/10-architecture.md`.
  """
  @spec warn_in_transaction(String.t()) :: :ok

  def warn_in_transaction(label) when is_binary(label) do
    if Config.dao().in_transaction?() do
      Logger.error(
        "внешний вызов внутри транзакции: #{label} — соединение с БД удерживается " <>
          "на время сетевого запроса"
      )
    end

    :ok
  end

  # ---

  defp to_ecto(:ok), do: {:ok, :none}
  defp to_ecto({:ok, _} = ok), do: ok
  defp to_ecto({:error, _} = err), do: err
end
