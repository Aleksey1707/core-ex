defmodule App.Facade do
  def to_int(x), do: App.Local.to_int(x)
  def to_int_guarded(x) when is_integer(x), do: App.Local.to_int(x)
  defdelegate delegated_to_int(x), to: App.Local, as: :to_int
  def status, do: App.Local.status()
  def dep_to_int(x), do: DepLib.to_int(x)
  def dep_status, do: DepLib.status()
end
