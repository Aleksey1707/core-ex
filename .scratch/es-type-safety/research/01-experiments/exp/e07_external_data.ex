defmodule E07.Evt do
  defstruct [:amount]
end

defmodule E07 do
  alias E07.Evt

  # JSON: string keys, atom-key access fails at runtime (KeyError)
  def json_atom_key(raw), do: JSON.decode!(raw).amount
  def string_key_param(%{"amount" => amount}) when is_integer(amount), do: byte_size(amount)

  def access_string_key_literal, do: byte_size(%{"amount" => 10}["amount"])
  def map_get_string_key_literal, do: byte_size(Map.get(%{"amount" => 10}, "amount"))
  def access_atom_key_literal, do: byte_size(%{amount: 1}[:amount])
  def map_get_atom_key_literal, do: byte_size(Map.get(%{amount: 1}, :amount))
  def dot_atom_key_literal, do: byte_size(%{amount: 1}.amount)

  def map_get_missing_on_struct(%Evt{} = e), do: Map.get(e, :amout)
  def map_update_bang_unknown(%Evt{} = e), do: Map.update!(e, :amout, & &1)
  def map_put_unknown_on_struct(%Evt{} = e), do: Map.put(e, :amout, 1)
  def access_on_struct(%Evt{} = e), do: e[:amount]

  def keyword_get_literal, do: byte_size(Keyword.get([timeout: 1], :timeout))
  def keyword_fetch_literal, do: byte_size(Keyword.fetch!([timeout: 1], :timeout))

  def enum_map_literal, do: Enum.map([1, 2], fn x -> byte_size(x) end)
  def enum_map_non_enumerable, do: Enum.map(123, & &1)
  def enum_at_literal, do: byte_size(Enum.at([1], 0))
  def for_literal, do: for(x <- [1, 2], do: byte_size(x))
  def hd_literal, do: byte_size(hd([1]))
end
