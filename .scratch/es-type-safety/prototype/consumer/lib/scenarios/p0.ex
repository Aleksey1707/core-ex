defmodule Blind.S.P0 do
  alias Blind.Account
  alias Blind.Order
  alias Blind.UserID
  alias Core.Context
  alias Core.Es
  alias Core.Version

  require Core.Config

  @repo Core.Config.repo!(Blind.Account.Repo)

  # A1 — команда чужого агрегата
  def a1_foreign_cmd(%Account{} = state, %Order.Cmd.Place{} = cmd),
    # expect: incompatible types given to Blind.Account.execute/2
    do: Account.execute(state, cmd)

  # A2 — команда без clause в decide/2
  def a2_no_decide_clause(%Account{} = state, %UserID{} = by, %Es.Event.At{} = at),
    # expect: incompatible types given to Blind.Account.execute/2
    do: Account.execute(state, %Account.Cmd.Orphan{by: by, at: at})

  # A3 — состояние чужого агрегата (ловилось и раньше)
  def a3_foreign_state(%Order{} = state, %Account.Cmd.Open{} = cmd),
    # expect: incompatible types given to Blind.Account.execute/2
    do: Account.execute(state, cmd)

  # A4a — {:ok, events} when is_list(events) (ловилось и раньше)
  def a4a_case_events_list(%Account{} = state, %Account.Cmd.Open{} = cmd) do
    case Account.execute(state, cmd) do
      # expect: the following clause will never match
      {:ok, events} when is_list(events) -> events
      {:error, _error} -> []
    end
  end

  # A5a — опечатка в поле возвращённого состояния
  def a5a_state_typo(%Account{} = state, %Account.Cmd.Open{} = cmd) do
    {:ok, {_events, executed}} = Account.execute(state, cmd)
    # expect: unknown key .nmae
    executed.nmae
  end

  # E5 — опечатка в поле состояния из {:ok, state}
  def e5_state_typo(%Account.ID{} = id, %Context{} = context) do
    # expect: unknown key .nmae
    with {:ok, state} <- @repo.get(id, :current, context), do: state.nmae
  end

  # E5b — то же у refresh
  def e5b_refresh_typo(%Account{} = state, %Context{} = context) do
    {:ok, refreshed} = @repo.refresh(state, :current, context)
    # expect: unknown key .nmae
    refreshed.nmae
  end

  # D2b — чужой ID из Order.ID.new/0 в конструкторе события
  def d2b_foreign_id_new(%Account.Event.Opened.Payload{} = payload, %UserID{} = by, %Es.Event.At{} = at),
    # expect: incompatible types given to Blind.Account.Event.Opened.new/5
    do: Account.Event.Opened.new(payload, Order.ID.new(), Version.new(), by, at)

  # E1b — чужой ID из Order.ID.new/0 в repo.get
  # expect: incompatible types given to Blind.Account.Repo.Pg.get/3
  def e1b_foreign_id_new(%Context{} = context), do: @repo.get(Order.ID.new(), :current, context)

  # F1b — чужой ID из Order.ID.new/0 в Process.execute
  def f1b_foreign_id_new(%Account.Cmd.Open{} = cmd, %Context{} = context),
    # expect: incompatible types given to Blind.Account.Process.execute/4
    do: Account.Process.execute(Order.ID.new(), :current, cmd, context)

  # F2 — команда чужого агрегата в Process.execute: слепая зона остаётся (маркера нет)
  def f2_foreign_cmd(%Account.ID{} = id, %Order.Cmd.Place{} = cmd, %Context{} = context),
    do: Account.Process.execute(id, :current, cmd, context)

  # F5 — невозможная clause по результату Process.execute
  def f5_case(%Account.ID{} = id, %Account.Cmd.Open{} = cmd, %Context{} = context) do
    case Account.Process.execute(id, :current, cmd, context) do
      # expect: the following clause will never match
      {:ok, state} -> state
      :ok -> nil
      {:error, _error} -> nil
    end
  end

  # E8 — {:ok, _} по результату append
  def e8_case_append(%Account.Event.Closed{} = event, %Context{} = context) do
    case @repo.append([event], context) do
      # expect: the following clause will never match
      {:ok, _} -> :ok
      :ok -> :ok
      {:error, _error} -> :error
    end
  end

  # A5a у агрегата, чей decide никогда не ошибается
  def a5a_never_fails_typo(%Blind.NeverFails{} = state, %Order.Cmd.Cancel{} = cmd) do
    {:ok, {_events, executed}} = Blind.NeverFails.execute(state, cmd)
    # expect: unknown key .nmae
    executed.nmae
  end

  # A1 у агрегата, чей decide всегда ошибается
  def a1_always_fails_foreign(%Blind.AlwaysFails{} = state, %Order.Cmd.Cancel{} = cmd),
    # expect: incompatible types given to Blind.AlwaysFails.execute/2
    do: Blind.AlwaysFails.execute(state, cmd)

  # Prim-конструкторы ядра без {:ok, _}: опечатка в поле результата
  # expect: unknown key .valeu
  def at_now_typo, do: Es.Event.At.now!().valeu
  # expect: unknown key .valeu
  def version_new_typo, do: Version.new().valeu
end
