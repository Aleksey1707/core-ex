defmodule E01.Evt do
  defstruct [:amount]
end

defmodule E01 do
  alias E01.Evt

  def stdlib_arg(x) when is_binary(x), do: Integer.to_string(x)

  def struct_field(%Evt{} = e), do: e.amout

  def map_key, do: %{a: 1}.b

  def tuple_index({_, _} = t), do: elem(t, 2)

  def never_match(x) when is_integer(x) do
    case x do
      "str" -> :never
      _ -> :ok
    end
  end

  def guard_never(x) when is_integer(x) and is_binary(x), do: :never

  def local_private, do: priv("s")
  defp priv(x) when is_integer(x), do: x

  def binary_concat(x) when is_integer(x), do: "a" <> x

  def compare(%Evt{} = e), do: e < ~D[2020-01-01]

  def dynamic_compatible(c) do
    v = if c, do: 1, else: "a"
    v + 1
  end

  def dynamic_disjoint(c) do
    v = if c, do: 1, else: "a"
    Map.fetch!(v, :k)
  end

  def fetch_bang, do: Map.fetch!(%{a: 1}, :b)

  def redundant(%Evt{}), do: 1
  def redundant(%Evt{}), do: 2
end
