defmodule E17 do
  def run(%{kind: :a} = e), do: handle(e)

  defp handle(%{kind: :a}), do: :a
  defp handle(%{kind: :b}), do: :b

  def public(%{kind: :a}), do: :a
  def public(%{kind: :b}), do: :b
end
