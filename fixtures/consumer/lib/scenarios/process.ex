defmodule Consumer.S.Process do
  @moduledoc "`Agg.Process.execute`: адрес, версия, колбэк, опции."

  alias Consumer.Account
  alias Consumer.Order
  alias Core.Context

  # F1 — ID другого агрегата из паттерна
  def f1_foreign_id(%Order.ID{} = id, %Account.Cmd.Open{} = command, %Context{} = context),
    # expect: incompatible types given to Consumer.Account.Process.execute/4
    do: Account.Process.execute(id, :current, command, context)

  # F1b — ID другого агрегата из `Order.ID.new()`
  def f1b_foreign_id_new(%Account.Cmd.Open{} = command, %Context{} = context),
    # expect: incompatible types given to Consumer.Account.Process.execute/4
    do: Account.Process.execute(Order.ID.new(), :current, command, context)

  # F3 — целое вместо версии
  def f3_integer_version(%Account.ID{} = id, %Account.Cmd.Open{} = command, %Context{} = context),
    # expect: incompatible types given to Consumer.Account.Process.execute/4
    do: Account.Process.execute(id, 1, command, context)

  # F4 — колбэк арности 2
  def f4_callback_arity(%Account.ID{} = id, %Account.Cmd.Open{} = command, %Context{} = context),
    # expect: incompatible types given to Consumer.Account.Process.execute/5
    do: Account.Process.execute(id, :current, command, context, fn _events, _extra -> :ok end)

  # F6 — map вместо keyword в `opts`
  def f6_opts_not_list(%Account.ID{} = id, %Account.Cmd.Open{} = command, %Context{} = context),
    # expect: incompatible types given to Consumer.Account.Process.execute/6
    do: Account.Process.execute(id, :current, command, context, nil, %{timeout: 1})

  # F5 — `{:ok, state}` по результату `Process.execute`
  def f5_case_ok_state(%Account.ID{} = id, %Account.Cmd.Open{} = command, %Context{} = context) do
    case Account.Process.execute(id, :current, command, context) do
      :ok -> nil
      # expect: the following clause will never match
      {:ok, state} -> state
      {:error, _error} -> nil
    end
  end
end
