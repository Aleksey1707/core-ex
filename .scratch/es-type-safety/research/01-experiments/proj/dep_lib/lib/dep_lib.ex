defmodule DepLib do
  def to_int(x) when is_integer(x), do: x
  def status, do: :ok
end

defmodule DepLib.Facade do
  def to_int(x), do: DepLib.to_int(x)
  def status, do: DepLib.status()
end

defprotocol DepLib.Dump do
  def dump(x)
end

defimpl DepLib.Dump, for: Integer do
  def dump(x), do: x
end
