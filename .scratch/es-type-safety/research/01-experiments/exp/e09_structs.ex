defmodule E09.Deposited do
  defstruct [:amount]
end

defmodule E09.Account do
  defstruct balance: 0
  alias E09.Deposited

  def pattern(%Deposited{} = e), do: e.amout
  def is_struct_guard(e) when is_struct(e, Deposited), do: e.amout
  def struct_key_pattern(%{__struct__: Deposited} = e), do: e.amout
  def var_struct_pattern(%mod{} = e) when mod == Deposited, do: e.amout

  def field_type_from_default, do: byte_size(%__MODULE__{}.balance)
  def field_type_param(%__MODULE__{} = s), do: byte_size(s.balance)

  def evolve(%__MODULE__{} = s, %Deposited{amount: a}), do: %{s | balance: s.balance + a}

  def update_unproven(s), do: %__MODULE__{s | balance: 1}
  def update_map_syntax(s), do: %{s | balance: 1}
  def update_proven(%__MODULE__{} = s), do: %__MODULE__{s | balance: 1}
  def update_unknown_field(%__MODULE__{} = s), do: %{s | balanse: 1}
end

defmodule E09.Caller do
  alias E09.{Account, Deposited}

  def wrong_field_value, do: Account.evolve(%Account{}, %Deposited{amount: "ten"})
  def wrong_event, do: Account.evolve(%Account{}, %Account{})
  def map_instead_of_struct, do: Account.evolve(%Account{}, %{amount: 1})

  def call_is_struct_guard, do: Account.is_struct_guard(%Deposited{amount: 1})
  def call_is_struct_guard_param(e), do: Account.is_struct_guard(e)

  def result_field do
    s = Account.evolve(%Account{}, %Deposited{amount: 1})
    byte_size(s.balance)
  end
end
