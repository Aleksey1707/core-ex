defmodule E23.Deposited do
  defstruct [:amount]
end

defmodule E23.Withdrawn do
  defstruct [:amount]
end

defmodule E23.Account do
  defstruct balance: 0
  def evolve(%__MODULE__{} = s, %E23.Deposited{amount: a}), do: %{s | balance: s.balance + a}
end

defmodule E23 do
  alias E23.{Account, Deposited, Withdrawn}

  def partial_union(flag) do
    event = if flag, do: %Deposited{amount: 1}, else: %Withdrawn{amount: 1}
    Account.evolve(%Account{}, event)
  end

  def fully_disjoint(flag) do
    event = if flag, do: %Withdrawn{amount: 2}, else: %Withdrawn{amount: 1}
    Account.evolve(%Account{}, event)
  end

  def non_exhaustive_case(flag) do
    event = if flag, do: %Deposited{amount: 1}, else: %Withdrawn{amount: 1}

    case event do
      %Deposited{} -> :deposited
    end
  end

  def events_list(events) when is_list(events), do: Enum.reduce(events, %Account{}, &Account.evolve(&2, &1))
end
