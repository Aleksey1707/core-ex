defmodule Core.EsFixture.Account.RacyRepo.Pg do
  @moduledoc """
  Write-репозиторий счёта с гонкой записи: делегирует в `Core.EsFixture.Account.Repo.Pg`, а перед
  первыми K `append` потока дописывает конкурирующее событие через `Core.Es.Store.append/5` —
  `Renamed` той же версии, что у первого события пачки. `append` получает `:version_mismatch`, как
  при записи конкурента.

  Конкурирующее событие пишется в транзакции команды и откатывается вместе с ней. K ставит
  `race/2`; счётчик — в публичной ETS-таблице процесса теста: гонку видит и `append` из другого
  процесса.
  """

  @behaviour Core.EsFixture.Account.RacyRepo

  alias Core.Context
  alias Core.Error
  alias Core.Es
  alias Core.EsFixture.Account
  alias Core.Pagination
  alias Core.Version

  @table __MODULE__

  @doc "Поставить гонку: перед следующими `count` `append` счёта `id` — конкурирующее событие."
  @spec race(Account.ID.t(), pos_integer()) :: :ok

  def race(%Account.ID{} = id, count) when is_integer(count) and count > 0 do
    if :ets.whereis(@table) == :undefined,
      do: :ets.new(@table, [:named_table, :public])

    true = :ets.insert(@table, {id, count})
    :ok
  end

  @doc "Состояние счёта из его потока."
  @spec get(Account.ID.t(), Version.expected(), Context.t(), keyword()) ::
          {:ok, Account.t()} | {:error, Error.t()}

  @impl true
  defdelegate get(id, version, context, opts \\ []), to: Account.Repo.Pg

  @doc "Решение `fun` над состоянием счёта из его потока."
  @spec get_decision(
          Account.ID.t(),
          Version.expected(),
          Context.t(),
          (Account.t() -> {:ok, decision} | {:error, reason}),
          keyword()
        ) :: {:ok, decision} | {:error, reason | Error.t()}
        when decision: var, reason: var

  @impl true
  defdelegate get_decision(id, version, context, fun, opts \\ []), to: Account.Repo.Pg

  @doc "Состояния счетов по парам `{id, version}`."
  @spec get_many([{Account.ID.t(), Version.expected()}], Context.t(), keyword()) ::
          {:ok, [Account.t()]} | {:error, Error.t()}

  @impl true
  defdelegate get_many(pairs, context, opts \\ []), to: Account.Repo.Pg

  @doc "Дочитать поток счёта после `state.version`."
  @spec refresh(Account.t(), Version.expected(), Context.t(), keyword()) ::
          {:ok, Account.t()} | {:error, Error.t()}

  @impl true
  defdelegate refresh(state, version, context, opts \\ []), to: Account.Repo.Pg

  @doc "Страница потока счёта."
  @spec page_stream(Account.ID.t(), Pagination.Limit.t(), Pagination.Offset.t(), Context.t()) ::
          {:ok, Pagination.Result.t(Es.Event.t())} | {:error, Error.t()}

  @impl true
  defdelegate page_stream(id, limit, offset, context), to: Account.Repo.Pg

  @doc "Записать события; перед поставленной гонкой — конкурирующее событие."
  @spec append([Es.Event.t()], Context.t(), keyword()) :: :ok | {:error, Error.t()}

  @impl true
  def append(events, %Context{} = context, opts \\ []) when is_list(events) and is_list(opts) do
    :ok = compete(events, context)
    Account.Repo.Pg.append(events, context, opts)
  end

  # ---

  defp compete([], _context), do: :ok

  defp compete([first | _events], context) do
    case take_race(first.aggregate_id) do
      :race -> append_rival(first, context)
      :none -> :ok
    end
  end

  defp take_race(id) do
    with tid when tid != :undefined <- :ets.whereis(@table),
         [{^id, count}] when count > 0 <- :ets.lookup(tid, id) do
      true = :ets.insert(tid, {id, count - 1})
      :race
    else
      _none -> :none
    end
  end

  defp append_rival(first, context) do
    payload = Account.Event.Renamed.Payload.new(Account.Name.new!("Конкурент"))

    rival =
      Account.Event.Renamed.new(
        payload,
        first.aggregate_id,
        first.aggregate_version,
        first.by,
        first.at
      )

    mismatch = &Account.Errors.domain(Account.RacyRepo, :version_mismatch, &1)
    Es.Store.append(Account.Event.Codec, [rival], context, mismatch, continuous?: true)
  end
end
