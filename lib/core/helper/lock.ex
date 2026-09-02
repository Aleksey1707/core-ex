defmodule Core.Helper.Lock do
  @moduledoc """
  Блокировки уровня БД (PostgreSQL advisory locks).

  Нужны разовым операциям, которые запускаются параллельно на нескольких узлах
  (инициализация системы при старте контейнера и т.п.).
  """

  @default_lock_timeout "5s"

  @doc """
  Взять исключительную advisory-блокировку на время транзакции.

  Снимается автоматически на commit / rollback. Вызывать только внутри транзакции.

  Ожидание ограничено `lock_timeout` (default `#{@default_lock_timeout}`, `:lock_timeout`
  в opts): зависший держатель иначе блокирует старт всех узлов бесконечно. Превышение —
  `Postgrex.Error` (`lock_not_available`), то есть падение старта с внятной причиной,
  а не тихое зависание. `:timeout` — таймаут самого запроса.
  """
  @spec advisory_xact!(Ecto.Repo.t(), integer(), keyword()) :: :ok

  def advisory_xact!(repo, key, opts \\ []) when is_integer(key) and is_list(opts) do
    set_lock_timeout!(repo, opts)
    Ecto.Adapters.SQL.query!(repo, "SELECT pg_advisory_xact_lock($1)", [key], query_opts(opts))

    :ok
  end

  @doc """
  Попытаться взять advisory-блокировку без ожидания.

  `true` — блокировка взята (до конца транзакции), `false` — её держит кто-то другой.
  Для операций, которые незанятый узел просто пропускает вместо того, чтобы ждать.
  """
  @spec try_advisory_xact(Ecto.Repo.t(), integer(), keyword()) :: boolean()

  def try_advisory_xact(repo, key, opts \\ []) when is_integer(key) and is_list(opts) do
    %{rows: [[acquired]]} =
      Ecto.Adapters.SQL.query!(
        repo,
        "SELECT pg_try_advisory_xact_lock($1)",
        [key],
        query_opts(opts)
      )

    acquired
  end

  # ---

  # `SET LOCAL` не принимает bind-параметры, а склейка значения в SQL — инъекция;
  # `set_config(..., true)` даёт тот же transaction-local эффект через параметр.
  defp set_lock_timeout!(repo, opts) do
    timeout = Keyword.get(opts, :lock_timeout, @default_lock_timeout)

    Ecto.Adapters.SQL.query!(
      repo,
      "SELECT set_config('lock_timeout', $1, true)",
      [timeout],
      query_opts(opts)
    )

    :ok
  end

  defp query_opts(opts), do: Keyword.take(opts, [:timeout])
end
