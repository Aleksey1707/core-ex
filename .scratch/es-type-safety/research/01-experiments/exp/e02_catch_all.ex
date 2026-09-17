defmodule E02.Rename do
  defstruct [:name]
end

defmodule E02.Strict do
  defstruct [:name]
  def decide(%E02.Rename{name: n}, %__MODULE__{}) when is_binary(n), do: {:ok, [n]}
end

defmodule E02.CatchAllRaise do
  defstruct [:name]
  def decide(%E02.Rename{name: n}, %__MODULE__{}) when is_binary(n), do: {:ok, [n]}
  def decide(cmd, _state), do: raise(ArgumentError, "unknown #{inspect(cmd)}")
end

defmodule E02.CatchAllError do
  defstruct [:name]
  def decide(%E02.Rename{name: n}, %__MODULE__{}) when is_binary(n), do: {:ok, [n]}
  def decide(_cmd, _state), do: {:error, :unknown_command}
end

defmodule E02.Caller do
  def strict, do: E02.Strict.decide("rename", %E02.Strict{})
  def raise_clause, do: E02.CatchAllRaise.decide("rename", %E02.CatchAllRaise{})
  def error_clause, do: E02.CatchAllError.decide("rename", %E02.CatchAllError{})

  def strict_result do
    case E02.Strict.decide(%E02.Rename{name: "a"}, %E02.Strict{}) do
      {:ok, events} -> events
      {:error, _} -> []
    end
  end

  def raise_result do
    case E02.CatchAllRaise.decide(%E02.Rename{name: "a"}, %E02.CatchAllRaise{}) do
      {:ok, events} -> events
      {:error, _} -> []
    end
  end
end
