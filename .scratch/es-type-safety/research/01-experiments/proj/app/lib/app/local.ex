defmodule App.Local do
  defstruct [:n]
  def to_int(x) when is_integer(x), do: x
  def status, do: :ok
end
