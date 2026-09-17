defmodule E11.Deposited do
  defstruct [:amount]
end

defmodule E11.Account do
  defstruct balance: 0
  def evolve(%__MODULE__{} = s, %E11.Deposited{amount: a}) when is_integer(a), do: %{s | balance: s.balance + a}
end

defmodule E11.Transact do
  def run(fun) when is_function(fun, 0), do: fun.()
  def call_with_string(fun), do: fun.("x")
end

defmodule E11 do
  alias E11.{Account, Deposited, Transact}

  def local_fn_wrong_arg do
    fun = fn %Deposited{} = e -> e end
    fun.("x")
  end

  def capture_wrong_arg do
    fun = &Account.evolve/2
    fun.(%Account{}, "bad event")
  end

  def capture_wrong_arity do
    fun = &Account.evolve/2
    fun.(%Account{})
  end

  def reduce_capture_args_swapped(events), do: Enum.reduce(events, %Account{}, &Account.evolve/2)

  def reduce_fn_wrong_events, do: Enum.reduce(["bad"], %Account{}, &Account.evolve(&2, &1))

  def reduce_literal_wrong_events do
    Enum.reduce([%Account{}], %Account{}, fn e, s -> Account.evolve(s, e) end)
  end

  def transact_wrong_arity, do: Transact.run(fn x -> x end)
  def transact_not_fun, do: Transact.run(:not_a_fun)
  def callback_param_wrong, do: Transact.call_with_string(fn %Deposited{} = e -> e end)
end
