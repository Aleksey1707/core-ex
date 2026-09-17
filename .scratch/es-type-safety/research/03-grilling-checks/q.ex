defmodule Q.Lib do
  def apply_decision(agg, state, _command, {:ok, results}) when is_atom(agg), do: {:ok, {results, state}}
  def apply_decision(_agg, _state, _command, {:error, _} = error), do: error
end

defmodule Q.Using do
  defmacro __using__(_opts) do
    quote do
      def execute(%__MODULE__{} = state, command) when is_struct(command) do
        case Q.Lib.apply_decision(__MODULE__, state, command, decide(command, state)) do
          {:ok, {events, %__MODULE__{} = state}} when is_list(events) -> {:ok, {events, state}}
          {:error, _} = error -> error
        end
      end
    end
  end
end

defmodule Q.Cmd.A do
  defstruct [:name, :by, :at]
end

defmodule Q.Cmd.B do
  defstruct [:by, :at]
end

defmodule Q.Other.Cmd do
  defstruct [:by, :at]
end

defmodule Q.E1 do
  defstruct [:payload]
end

defmodule Q.E2 do
  defstruct [:payload]
end

defmodule Q.Agg do
  use Q.Using
  defstruct [:id, :version, :name]

  def decide(%Q.Cmd.A{name: n}, %__MODULE__{}), do: {:ok, [{Q.E1, n}]}
  def decide(%Q.Cmd.B{}, %__MODULE__{}), do: {:ok, []}

  def evolve(%__MODULE__{} = s, %Q.E1{}), do: s
end

defmodule Q.Repo do
  @doc false
  def __es_check_evolve__(%Q.Agg{} = s, %Q.E1{} = e1, %Q.E2{} = e2),
    do: {Q.Agg.evolve(s, e1), Q.Agg.evolve(s, e2)}
end

defmodule Q.Caller do
  def foreign(%Q.Agg{} = s, %Q.Other.Cmd{} = c), do: Q.Agg.execute(s, c)
  def ok(%Q.Agg{} = s, %Q.Cmd.B{} = c), do: Q.Agg.execute(s, c)
  def typo(%Q.Agg{} = s, %Q.Cmd.B{} = c) do
    {:ok, {_events, state}} = Q.Agg.execute(s, c)
    state.nmae
  end
end
