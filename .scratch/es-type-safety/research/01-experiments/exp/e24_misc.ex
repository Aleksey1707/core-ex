defmodule E24.Evt do
  defstruct [:amount]
end

defmodule E24.Guards do
  defguard is_evt(x) when is_struct(x, E24.Evt)
  defguard is_evt_or_nil(x) when is_nil(x) or is_struct(x, E24.Evt)
end

defmodule E24 do
  import E24.Guards

  def defguard_struct(e) when is_evt(e), do: e.amout
  def pattern_struct(%E24.Evt{} = e), do: e.amout

  def upcase_result(x), do: String.upcase(x) + 1
  def to_string_result(x), do: Integer.to_string(x) + 1

  def erlang_builtin, do: :erlang.atom_to_binary("not an atom")
  def erlang_otp_module, do: :lists.reverse(:not_a_list)
  def erlang_crypto, do: :crypto.strong_rand_bytes("not an integer")
end
