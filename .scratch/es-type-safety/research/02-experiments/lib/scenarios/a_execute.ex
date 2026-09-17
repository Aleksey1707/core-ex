defmodule Blind.S.Execute do
  alias Blind.Account
  alias Blind.Order
  alias Blind.UserID
  alias Core.Context
  alias Core.Es

  require Core.Config

  @repo Core.Config.repo!(Blind.Account.Repo)

  # A1 — команда чужого агрегата
  def a1_foreign_cmd(%Account{} = state, %Order.Cmd.Place{} = cmd),
    do: Account.execute(state, cmd)

  # A2 — команда без clause в decide/2
  def a2_no_decide_clause(%Account{} = state, %UserID{} = by, %Es.Event.At{} = at),
    do: Account.execute(state, %Account.Cmd.Orphan{by: by, at: at})

  # A3 — состояние чужого агрегата
  def a3_foreign_state(%Order{} = state, %Account.Cmd.Open{} = cmd),
    do: Account.execute(state, cmd)

  # A4a — case: {:ok, events} when is_list(events) вместо {:ok, {events, state}}
  def a4a_case_events_list(%Account{} = state, %Account.Cmd.Open{} = cmd) do
    case Account.execute(state, cmd) do
      {:ok, events} when is_list(events) -> events
      {:error, _error} -> []
    end
  end

  # A4b — with {:ok, events} и передача кортежа в append (как в usecase)
  def a4b_with_append(%Account{} = state, %Account.Cmd.Open{} = cmd, %Context{} = context) do
    with {:ok, events} <- Account.execute(state, cmd) do
      @repo.append(events, context)
    end
  end

  # A4c — case: :ok -> (невозможный вариант)
  def a4c_case_ok_atom(%Account{} = state, %Account.Cmd.Open{} = cmd) do
    case Account.execute(state, cmd) do
      :ok -> :ok
      {:error, _error} -> :error
      {:ok, {_events, _state}} -> :ok
    end
  end

  # A5a — опечатка в поле возвращённого состояния
  def a5a_state_typo(%Account{} = state, %Account.Cmd.Open{} = cmd) do
    {:ok, {_events, executed}} = Account.execute(state, cmd)
    executed.nmae
  end

  # A5b — то же, состояние сопоставлено с %Account{}
  def a5b_state_typo_matched(%Account{} = state, %Account.Cmd.Open{} = cmd) do
    {:ok, {_events, %Account{} = executed}} = Account.execute(state, cmd)
    executed.nmae
  end

  # A5c — опечатка в поле события из результата
  def a5c_event_typo(%Account{} = state, %Account.Cmd.Open{} = cmd) do
    {:ok, {[event | _], _executed}} = Account.execute(state, cmd)
    event.aggregat_id
  end

  # A6 — struct без by/at вместо команды
  def a6_not_a_command(%Account{} = state, %Account.Name{} = name), do: Account.execute(state, name)

  # A7 — map вместо struct команды
  def a7_map_command(%Account{} = state, %UserID{} = by, %Es.Event.At{} = at),
    do: Account.execute(state, %{by: by, at: at})

  # ===== те же ошибки прямым вызовом decide/2 =====

  def d1_foreign_cmd(%Account{} = state, %Order.Cmd.Place{} = cmd),
    do: Account.decide(cmd, state)

  def d2_no_decide_clause(%Account{} = state, %UserID{} = by, %Es.Event.At{} = at),
    do: Account.decide(%Account.Cmd.Orphan{by: by, at: at}, state)

  def d3_foreign_state(%Order{} = state, %Account.Cmd.Open{} = cmd),
    do: Account.decide(cmd, state)

  def d4_case_state_tuple(%Account{} = state, %Account.Cmd.Open{} = cmd) do
    case Account.decide(cmd, state) do
      {:ok, {events, _state}} -> events
      {:error, _error} -> []
    end
  end

  def d5_payload_typo(%Account.Cmd.Open{} = cmd, %Account{version: nil} = state) do
    {:ok, [{_mod, payload}]} = Account.decide(cmd, state)
    payload.nmae
  end
end
