defmodule E05.Aggregate do
  @callback evolve(state :: struct(), event :: struct()) :: struct()

  def fold(mod, state, events) when is_atom(mod) and is_list(events),
    do: Enum.reduce(events, state, &mod.evolve(&2, &1))

  def fold_one(mod, state, event), do: mod.evolve(state, event)
end

defmodule E05.Account do
  @behaviour E05.Aggregate
  defstruct [:balance]

  @spec deposit(integer()) :: binary()
  def deposit(amount), do: amount

  @spec bump(binary()) :: binary()
  def bump(n) when is_integer(n), do: n + 1

  @impl true
  @spec evolve(integer(), atom()) :: atom()
  def evolve(%__MODULE__{} = s, {:deposited, n}) when is_integer(n), do: %{s | balance: n}
end

defmodule E05.Caller do
  def spec_arg, do: E05.Account.deposit("not an integer")

  def spec_return do
    case E05.Account.deposit(1) do
      b when is_binary(b) -> b
    end
  end

  def spec_contradiction do
    case E05.Account.bump(1) do
      b when is_binary(b) -> b
    end
  end

  def through_behaviour_var, do: E05.Aggregate.fold_one(E05.Account, %E05.Account{}, "bad event")

  def through_reduce, do: E05.Aggregate.fold(E05.Account, %E05.Account{}, ["bad event"])

  def direct, do: E05.Account.evolve(%E05.Account{}, "bad event")
end
