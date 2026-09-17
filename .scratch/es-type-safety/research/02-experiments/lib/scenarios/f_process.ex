defmodule Blind.S.Process do
  alias Blind.Account
  alias Blind.Order
  alias Core.Context

  # F1 — чужой ID
  def f1_foreign_id(%Order.ID{} = id, %Account.Cmd.Open{} = cmd, %Context{} = context),
    do: Account.Process.execute(id, :current, cmd, context)

  # F1b — чужой ID из Order.ID.new/0
  def f1b_foreign_id_new(%Account.Cmd.Open{} = cmd, %Context{} = context),
    do: Account.Process.execute(Order.ID.new(), :current, cmd, context)

  # F2 — команда чужого агрегата
  def f2_foreign_cmd(%Account.ID{} = id, %Order.Cmd.Place{} = cmd, %Context{} = context),
    do: Account.Process.execute(id, :current, cmd, context)

  # F3 — целое вместо версии
  def f3_int_version(%Account.ID{} = id, %Account.Cmd.Open{} = cmd, %Context{} = context),
    do: Account.Process.execute(id, 1, cmd, context)

  # F4 — колбэк арности 2
  def f4_fun_arity2(%Account.ID{} = id, %Account.Cmd.Open{} = cmd, %Context{} = context),
    do: Account.Process.execute(id, :current, cmd, context, fn _events, _extra -> :ok end)

  # F4b — колбэк возвращает не :ok | {:error, _}
  def f4b_fun_bad_return(%Account.ID{} = id, %Account.Cmd.Open{} = cmd, %Context{} = context),
    do: Account.Process.execute(id, :current, cmd, context, fn events -> {:ok, events} end)

  # F4c — колбэк ждёт одно событие, а приходит список
  def f4c_fun_event_pattern(%Account.ID{} = id, %Account.Cmd.Open{} = cmd, %Context{} = context),
    do: Account.Process.execute(id, :current, cmd, context, fn %Account.Event.Opened{} -> :ok end)

  # F5 — невозможная clause по результату
  def f5_case(%Account.ID{} = id, %Account.Cmd.Open{} = cmd, %Context{} = context) do
    case Account.Process.execute(id, :current, cmd, context) do
      {:ok, state} -> state
      :ok -> nil
      {:error, _error} -> nil
    end
  end

  # F6 — опции: неизвестный ключ и не-keyword
  def f6_opts_not_list(%Account.ID{} = id, %Account.Cmd.Open{} = cmd, %Context{} = context),
    do: Account.Process.execute(id, :current, cmd, context, nil, %{timeout: 1})
end
