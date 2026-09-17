defmodule Blind.S.Cmd do
  alias Blind.Account
  alias Blind.Order
  alias Core.Es

  # I1 — by не того Prim
  def i1_by_foreign(%Account{} = state, %Account.Name{} = name, %Order.ID{} = by, %Es.Event.At{} = at),
    do: Account.execute(state, %Account.Cmd.Open{name: name, by: by, at: at})

  # I2 — at не того Prim
  def i2_at_datetime(%Account{} = state, %Account.Name{} = name, %Blind.UserID{} = by),
    do: Account.execute(state, %Account.Cmd.Open{name: name, by: by, at: DateTime.utc_now()})

  # I3 — поле команды не Prim
  def i3_name_string(%Account{} = state, %Blind.UserID{} = by, %Es.Event.At{} = at),
    do: Account.execute(state, %Account.Cmd.Open{name: "строка", by: by, at: at})

  # I4 — прямой decide/2 с by не того Prim
  def i4_decide_by_foreign(%Account{} = state, %Account.Name{} = name, %Order.ID{} = by, %Es.Event.At{} = at),
    do: Account.decide(%Account.Cmd.Open{name: name, by: by, at: at}, state)
end
