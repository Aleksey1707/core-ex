defmodule Consumer.S.Orphan do
  @moduledoc "Команда, которую `decide/2` счёта не разбирает."

  use Core.Es.Cmd

  @enforce_keys ~w(by at)a
  defstruct @enforce_keys
end

defmodule Consumer.S.Execute do
  @moduledoc "`Agg.execute/2` и прямой `decide/2`: ошибки вызова и разбора результата."

  alias Consumer.Account
  alias Consumer.AlwaysFails
  alias Consumer.NeverFails
  alias Consumer.Order
  alias Consumer.S.Orphan
  alias Consumer.UserID
  alias Core.Context
  alias Core.Es

  require Core.Config

  @repo Core.Config.repo!(Consumer.Account.Repo)

  # A1 — команда другого агрегата
  def a1_foreign_command(%Account{} = state, %Order.Cmd.Place{} = command),
    # expect: incompatible types given to Consumer.Account.execute/2
    do: Account.execute(state, command)

  # A1 у агрегата, чей `decide/2` всегда возвращает ошибку
  def a1_always_fails_foreign_command(%AlwaysFails{} = state, %Order.Cmd.Cancel{} = command),
    # expect: incompatible types given to Consumer.AlwaysFails.execute/2
    do: AlwaysFails.execute(state, command)

  # A2 — команда без clause в `decide/2`
  def a2_no_decide_clause(%Account{} = state, %UserID{} = by, %Es.Event.At{} = at),
    # expect: incompatible types given to Consumer.Account.execute/2
    do: Account.execute(state, %Orphan{by: by, at: at})

  # A3 — состояние другого агрегата
  def a3_foreign_state(%Order{} = state, %Account.Cmd.Open{} = command),
    # expect: incompatible types given to Consumer.Account.execute/2
    do: Account.execute(state, command)

  # A4a — `{:ok, events}` вместо `{:ok, {events, state}}`
  def a4a_case_events_list(%Account{} = state, %Account.Cmd.Open{} = command) do
    case Account.execute(state, command) do
      # expect: the following clause will never match
      {:ok, events} when is_list(events) -> events
      {:error, _error} -> []
    end
  end

  # A4b — кортеж результата передан в `append` как список событий
  def a4b_with_append(%Account{} = state, %Account.Cmd.Open{} = command, %Context{} = context) do
    with {:ok, events} <- Account.execute(state, command) do
      # expect: incompatible types given to Consumer.Account.Repo.Pg.append/2
      @repo.append(events, context)
    end
  end

  # A4c — `:ok` по результату `execute`
  def a4c_case_ok(%Account{} = state, %Account.Cmd.Open{} = command) do
    case Account.execute(state, command) do
      # expect: the following clause will never match
      :ok -> :ok
      {:ok, {_events, _state}} -> :ok
      {:error, _error} -> :error
    end
  end

  # A5a — опечатка в поле состояния из результата
  def a5a_state_typo(%Account{} = state, %Account.Cmd.Open{} = command) do
    {:ok, {_events, executed}} = Account.execute(state, command)
    # expect: unknown key .nmae
    executed.nmae
  end

  # A5a у агрегата, чей `decide/2` никогда не возвращает ошибку
  def a5a_never_fails_state_typo(%NeverFails{} = state, %Order.Cmd.Cancel{} = command) do
    {:ok, {_events, executed}} = NeverFails.execute(state, command)
    # expect: unknown key .nmae
    executed.nmae
  end

  # A5b — опечатка в поле состояния, суженного `%Account{}`
  def a5b_state_typo_matched(%Account{} = state, %Account.Cmd.Open{} = command) do
    {:ok, {_events, %Account{} = executed}} = Account.execute(state, command)
    # expect: unknown key .nmae
    executed.nmae
  end

  # A6 — struct без `by` / `at` вместо команды
  def a6_not_a_command(%Account{} = state, %Account.Name{} = name),
    # expect: incompatible types given to Consumer.Account.execute/2
    do: Account.execute(state, name)

  # A7 — map вместо struct команды
  def a7_map_command(%Account{} = state, %UserID{} = by, %Es.Event.At{} = at),
    # expect: incompatible types given to Consumer.Account.execute/2
    do: Account.execute(state, %{by: by, at: at})

  # A-d1 — прямой `decide/2`: команда другого агрегата
  def d1_foreign_command(%Account{} = state, %Order.Cmd.Place{} = command),
    # expect: incompatible types given to Consumer.Account.decide/2
    do: Account.decide(command, state)

  # A-d2 — прямой `decide/2`: команда без clause
  def d2_no_decide_clause(%Account{} = state, %UserID{} = by, %Es.Event.At{} = at),
    # expect: incompatible types given to Consumer.Account.decide/2
    do: Account.decide(%Orphan{by: by, at: at}, state)

  # A-d3 — прямой `decide/2`: состояние другого агрегата
  def d3_foreign_state(%Order{} = state, %Account.Cmd.Open{} = command),
    # expect: incompatible types given to Consumer.Account.decide/2
    do: Account.decide(command, state)

  # A-d4 — прямой `decide/2`: `{:ok, {events, state}}` вместо `{:ok, results}`
  def d4_case_state_tuple(%Account{} = state, %Account.Cmd.Open{} = command) do
    case Account.decide(command, state) do
      # expect: the following clause will never match
      {:ok, {events, _state}} -> events
      {:error, _error} -> []
    end
  end
end
