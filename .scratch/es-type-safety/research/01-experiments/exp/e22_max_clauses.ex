defmodule E22.Ev1 do
  defstruct [:v]
end

defmodule E22.Ev2 do
  defstruct [:v]
end

defmodule E22.Ev3 do
  defstruct [:v]
end

defmodule E22.Ev4 do
  defstruct [:v]
end

defmodule E22.Ev5 do
  defstruct [:v]
end

defmodule E22.Ev6 do
  defstruct [:v]
end

defmodule E22.Ev7 do
  defstruct [:v]
end

defmodule E22.Ev8 do
  defstruct [:v]
end

defmodule E22.Ev9 do
  defstruct [:v]
end

defmodule E22.Ev10 do
  defstruct [:v]
end

defmodule E22.Ev11 do
  defstruct [:v]
end

defmodule E22.Ev12 do
  defstruct [:v]
end

defmodule E22.Ev13 do
  defstruct [:v]
end

defmodule E22.Ev14 do
  defstruct [:v]
end

defmodule E22.Ev15 do
  defstruct [:v]
end

defmodule E22.Ev16 do
  defstruct [:v]
end

defmodule E22.Ev17 do
  defstruct [:v]
end

defmodule E22.Ev18 do
  defstruct [:v]
end

defmodule E22.Ev19 do
  defstruct [:v]
end

defmodule E22.Ev20 do
  defstruct [:v]
end

defmodule E22.Big do
  def evolve(:state, %E22.Ev1{}), do: {:state, :s1}
  def evolve(:state, %E22.Ev2{}), do: {:state, :s2}
  def evolve(:state, %E22.Ev3{}), do: {:state, :s3}
  def evolve(:state, %E22.Ev4{}), do: {:state, :s4}
  def evolve(:state, %E22.Ev5{}), do: {:state, :s5}
  def evolve(:state, %E22.Ev6{}), do: {:state, :s6}
  def evolve(:state, %E22.Ev7{}), do: {:state, :s7}
  def evolve(:state, %E22.Ev8{}), do: {:state, :s8}
  def evolve(:state, %E22.Ev9{}), do: {:state, :s9}
  def evolve(:state, %E22.Ev10{}), do: {:state, :s10}
  def evolve(:state, %E22.Ev11{}), do: {:state, :s11}
  def evolve(:state, %E22.Ev12{}), do: {:state, :s12}
  def evolve(:state, %E22.Ev13{}), do: {:state, :s13}
  def evolve(:state, %E22.Ev14{}), do: {:state, :s14}
  def evolve(:state, %E22.Ev15{}), do: {:state, :s15}
  def evolve(:state, %E22.Ev16{}), do: {:state, :s16}
  def evolve(:state, %E22.Ev17{}), do: {:state, :s17}
  def evolve(:state, %E22.Ev18{}), do: {:state, :s18}
  def evolve(:state, %E22.Ev19{}), do: {:state, :s19}
  def evolve(:state, %E22.Ev20{}), do: {:state, :s20}
end

defmodule E22.Small do
  def evolve(:state, %E22.Ev1{}), do: {:state, :s1}
  def evolve(:state, %E22.Ev2{}), do: {:state, :s2}
  def evolve(:state, %E22.Ev3{}), do: {:state, :s3}
end

defmodule E22.Caller do
  def big_dynamic(e) do
    case E22.Big.evolve(:state, e) do
      {:state, _} -> :ok
      :impossible -> :never
    end
  end

  def small_dynamic(e) do
    case E22.Small.evolve(:state, e) do
      {:state, _} -> :ok
      :impossible -> :never
    end
  end

  def big_literal do
    case E22.Big.evolve(:state, %E22.Ev1{}) do
      {:state, _} -> :ok
      :impossible -> :never
    end
  end

  def big_wrong_arg, do: E22.Big.evolve(:state, "not an event")
end
