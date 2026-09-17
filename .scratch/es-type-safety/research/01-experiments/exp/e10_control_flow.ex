defmodule E10.Decider do
  def decide(n) when is_integer(n), do: {:ok, [n]}
end

defmodule E10 do
  alias E10.Decider

  def case_dead_clause do
    case Decider.decide(1) do
      {:ok, events} -> events
      {:error, reason} -> reason
    end
  end

  def case_wildcard do
    case Decider.decide(1) do
      {:ok, events} -> events
      _ -> :unreachable
    end
  end

  def case_wildcard_first do
    case Decider.decide(1) do
      _ -> :first
      {:ok, events} -> events
    end
  end

  def with_else_dead do
    with {:ok, events} <- Decider.decide(1) do
      events
    else
      {:error, reason} -> reason
    end
  end

  def with_else_wildcard do
    with {:ok, events} <- Decider.decide(1) do
      events
    else
      _ -> :unreachable
    end
  end

  def with_never_matches do
    with {:error, reason} <- Decider.decide(1) do
      reason
    end
  end

  def try_result(s) do
    x =
      try do
        Integer.parse(s)
      rescue
        _ -> nil
      end

    byte_size(x)
  end

  def rescue_field do
    Integer.parse("1")
  rescue
    e in ArgumentError -> e.mesage
  end

  def first_error_only do
    a = Integer.to_string("a")
    b = byte_size(1)
    {a, b}
  end

  def branches_each_reported(flag) do
    if flag do
      Integer.to_string("a")
    else
      byte_size(1)
    end
  end
end
