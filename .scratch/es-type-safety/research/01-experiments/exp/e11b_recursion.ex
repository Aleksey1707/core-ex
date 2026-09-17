defmodule E11b.Deposited do
  defstruct [:amount]
end

defmodule E11b.Account do
  defstruct balance: 0
  def evolve(%__MODULE__{} = s, %E11b.Deposited{amount: a}) when is_integer(a), do: %{s | balance: s.balance + a}

  def fold_reduce(state, events), do: Enum.reduce(events, state, &evolve(&2, &1))

  def fold_rec(state, []), do: state
  def fold_rec(state, [event | rest]), do: fold_rec(evolve(state, event), rest)
end

defmodule E11b.Caller do
  alias E11b.Account

  def via_reduce, do: Account.fold_reduce(%Account{}, ["bad"])
  def via_recursion, do: Account.fold_rec(%Account{}, ["bad"])
end
