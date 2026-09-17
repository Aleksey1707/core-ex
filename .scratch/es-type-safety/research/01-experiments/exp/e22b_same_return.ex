defmodule E22b.Ev1 do
  defstruct [:v]
end

defmodule E22b.Ev2 do
  defstruct [:v]
end

defmodule E22b.Ev3 do
  defstruct [:v]
end

defmodule E22b.Ev4 do
  defstruct [:v]
end

defmodule E22b.Ev5 do
  defstruct [:v]
end

defmodule E22b.Ev6 do
  defstruct [:v]
end

defmodule E22b.Ev7 do
  defstruct [:v]
end

defmodule E22b.Ev8 do
  defstruct [:v]
end

defmodule E22b.Ev9 do
  defstruct [:v]
end

defmodule E22b.Ev10 do
  defstruct [:v]
end

defmodule E22b.Ev11 do
  defstruct [:v]
end

defmodule E22b.Ev12 do
  defstruct [:v]
end

defmodule E22b.Ev13 do
  defstruct [:v]
end

defmodule E22b.Ev14 do
  defstruct [:v]
end

defmodule E22b.Ev15 do
  defstruct [:v]
end

defmodule E22b.Ev16 do
  defstruct [:v]
end

defmodule E22b.Ev17 do
  defstruct [:v]
end

defmodule E22b.Ev18 do
  defstruct [:v]
end

defmodule E22b.Ev19 do
  defstruct [:v]
end

defmodule E22b.Ev20 do
  defstruct [:v]
end

defmodule E22b.SameReturn do
  def evolve(:state, %E22b.Ev1{}), do: {:state, 1}
  def evolve(:state, %E22b.Ev2{}), do: {:state, 2}
  def evolve(:state, %E22b.Ev3{}), do: {:state, 3}
  def evolve(:state, %E22b.Ev4{}), do: {:state, 4}
  def evolve(:state, %E22b.Ev5{}), do: {:state, 5}
  def evolve(:state, %E22b.Ev6{}), do: {:state, 6}
  def evolve(:state, %E22b.Ev7{}), do: {:state, 7}
  def evolve(:state, %E22b.Ev8{}), do: {:state, 8}
  def evolve(:state, %E22b.Ev9{}), do: {:state, 9}
  def evolve(:state, %E22b.Ev10{}), do: {:state, 10}
  def evolve(:state, %E22b.Ev11{}), do: {:state, 11}
  def evolve(:state, %E22b.Ev12{}), do: {:state, 12}
  def evolve(:state, %E22b.Ev13{}), do: {:state, 13}
  def evolve(:state, %E22b.Ev14{}), do: {:state, 14}
  def evolve(:state, %E22b.Ev15{}), do: {:state, 15}
  def evolve(:state, %E22b.Ev16{}), do: {:state, 16}
  def evolve(:state, %E22b.Ev17{}), do: {:state, 17}
  def evolve(:state, %E22b.Ev18{}), do: {:state, 18}
  def evolve(:state, %E22b.Ev19{}), do: {:state, 19}
  def evolve(:state, %E22b.Ev20{}), do: {:state, 20}
end
