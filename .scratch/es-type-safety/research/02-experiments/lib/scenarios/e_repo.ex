defmodule Blind.S.Repo do
  alias Blind.Account
  alias Blind.Order
  alias Core.Context

  require Core.Config

  @repo Core.Config.repo!(Blind.Account.Repo)

  # E1 — чужой ID (из паттерна в голове)
  def e1_foreign_id(%Order.ID{} = id, %Context{} = context), do: @repo.get(id, :current, context)

  # E1b — чужой ID из Order.ID.new/0
  def e1b_foreign_id_new(%Context{} = context), do: @repo.get(Order.ID.new(), :current, context)

  # E2 — целое вместо %Version{} / :current
  def e2_int_version(%Account.ID{} = id, %Context{} = context), do: @repo.get(id, 1, context)

  # E2b — строка "*" вместо :current
  def e2b_string_version(%Account.ID{} = id, %Context{} = context), do: @repo.get(id, "*", context)

  # E3 — не-событие в append
  def e3_append_not_event(%Context{} = context), do: @repo.append(["bad"], context)

  def e3b_append_state(%Account{} = state, %Context{} = context), do: @repo.append([state], context)

  def e3c_append_not_list(%Account.Event.Closed{} = event, %Context{} = context),
    do: @repo.append(event, context)

  # E4 — невозможные clauses по результату get
  def e4_case_get(%Account.ID{} = id, %Context{} = context) do
    case @repo.get(id, :current, context) do
      {:ok, {_events, state}} -> state
      :ok -> nil
      {:error, _error} -> nil
    end
  end

  # E4b — clause на доменную ошибку с другим кодом
  def e4b_case_not_found(%Account.ID{} = id, %Context{} = context) do
    case @repo.get(id, :current, context) do
      {:ok, state} -> state
      {:error, %Core.Error{code: :not_found}} -> nil
      {:error, _error} -> nil
    end
  end

  # E5 — опечатка в поле состояния из {:ok, state}
  def e5_state_typo(%Account.ID{} = id, %Context{} = context) do
    with {:ok, state} <- @repo.get(id, :current, context), do: state.nmae
  end

  # E6 — get_many с чужим ID
  def e6_get_many_foreign(%Order.ID{} = id, %Context{} = context),
    do: @repo.get_many([{id, :current}], context)

  # E7 — refresh чужого состояния
  def e7_refresh_foreign_state(%Order{} = state, %Context{} = context),
    do: @repo.refresh(state, :current, context)

  # E8 — case по результату append
  def e8_case_append(%Account.Event.Closed{} = event, %Context{} = context) do
    case @repo.append([event], context) do
      {:ok, _} -> :ok
      :ok -> :ok
      {:error, _error} -> :error
    end
  end
end
