defmodule E04.Id do
  defstruct [:value]
end

defmodule E04.RepoBehaviour do
  @callback get(id :: integer()) :: {:ok, term()} | {:error, term()}
end

defmodule E04.Using do
  defmacro __using__(opts) do
    id = Keyword.fetch!(opts, :id)
    body =
      quote do
        @behaviour E04.RepoBehaviour

        @impl true
        def get(%unquote(id){} = id), do: {:ok, id}

        def buggy, do: Integer.to_string("not an int")

        def get_or_default(id), do: get(id)

        defoverridable get: 1
      end

    if Keyword.get(opts, :generated, false) do
      Macro.prewalk(body, fn
        {name, meta, args} -> {name, [generated: true] ++ meta, args}
        other -> other
      end)
    else
      body
    end
  end
end

defmodule E04.Plain do
  use E04.Using, id: E04.Id
end

defmodule E04.Generated do
  use E04.Using, id: E04.Id, generated: true
end

defmodule E04.Overridden do
  use E04.Using, id: E04.Id

  @impl true
  def get(%E04.Id{value: v} = id) when is_integer(v), do: super(id)
end

defmodule E04.BeforeCompile do
  defmacro __before_compile__(_env) do
    quote do
      def evolve(state, _event), do: state
    end
  end
end

defmodule E04.Agg do
  @before_compile E04.BeforeCompile
  defstruct [:n]
  def evolve(%__MODULE__{} = s, %E04.Id{}), do: s
end

defmodule E04.Caller do
  def plain, do: E04.Plain.get("x")
  def generated, do: E04.Generated.get("x")
  def overridden, do: E04.Overridden.get(%E04.Id{value: "x"})
  def default_wrapper, do: E04.Plain.get_or_default("x")
  def before_compile, do: E04.Agg.evolve(%E04.Agg{}, "not an event")
end
