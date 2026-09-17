defmodule Q2.Lib do
  def apply_decision(agg, state, _command, {:ok, results}) when is_atom(agg), do: {:ok, {results, state}}
  def apply_decision(_agg, _state, _command, {:error, _} = error), do: error
end

defmodule Q2.Using do
  defmacro __using__(_opts) do
    quote generated: true do
      def execute(%__MODULE__{} = state, command) when is_struct(command) do
        case Q2.Lib.apply_decision(__MODULE__, state, command, decide(command, state)) do
          {:ok, {events, %__MODULE__{} = state}} when is_list(events) -> {:ok, {events, state}}
          {:error, _} = error -> error
        end
      end
    end
  end
end

defmodule Q2.Cmd.A do
  defstruct [:name, :by, :at]
end

defmodule Q2.Cmd.B do
  defstruct [:by, :at]
end

defmodule Q2.Other.Cmd do
  defstruct [:by, :at]
end

defmodule Q2.E1 do
  defstruct [:payload]
end

defmodule Q2.E2 do
  defstruct [:payload]
end

defmodule Q2.Agg do
  use Q2.Using
  defstruct [:id, :version, :name]

  def decide(%Q2.Cmd.A{name: n}, %__MODULE__{}), do: {:ok, [{Q2.E1, n}]}
  def decide(%Q2.Cmd.B{}, %__MODULE__{}), do: {:ok, []}

  def evolve(%__MODULE__{} = s, %Q2.E1{}), do: s
end

defmodule Q2.Repo do
  @doc false
  def __es_check_evolve__(%Q2.Agg{} = s, %Q2.E1{} = e1, %Q2.E2{} = e2),
    do: {Q2.Agg.evolve(s, e1), Q2.Agg.evolve(s, e2)}
end

defmodule Q2.Caller do
  def foreign(%Q2.Agg{} = s, %Q2.Other.Cmd{} = c), do: Q2.Agg.execute(s, c)
  def ok(%Q2.Agg{} = s, %Q2.Cmd.B{} = c), do: Q2.Agg.execute(s, c)
  def typo(%Q2.Agg{} = s, %Q2.Cmd.B{} = c) do
    {:ok, {_events, state}} = Q2.Agg.execute(s, c)
    state.nmae
  end
end
