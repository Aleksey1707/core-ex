defmodule Core.Field.Meta.Personal do
  @moduledoc false

  alias Core.Helper.Opts

  @spec key() :: atom()
  def key, do: :personal

  @spec roles() :: [atom()]
  def roles, do: ~w(struct payload labels)a

  @spec normalize!(term(), map()) :: term()
  def normalize!(nil, _ctx), do: nil
  def normalize!(raw, _ctx) when is_boolean(raw), do: raw

  def normalize!(raw, %{where: where}),
    do: Opts.reject!("#{where}: personal", "ожидается boolean, получено #{inspect(raw)}")

  @spec read_extra(map(), map()) :: :none | {:union, Macro.t()}
  def read_extra(field, ctx) do
    if place?(field, ctx), do: {:union, quote(do: Core.Es.Personal.Destroyed.t())}, else: :none
  end

  @spec write_reject(map(), map()) :: :ok | {:reject, String.t()}
  def write_reject(_field, _ctx), do: :ok

  @spec plan_extra([atom()], map(), map()) :: [map()]
  def plan_extra(_path, _field, _ctx), do: []

  @spec inspect_policy(map(), map()) :: :keep | :hide_value | :hide_all
  def inspect_policy(field, ctx) do
    cond do
      place?(field, ctx) -> :hide_all
      nested_place?(field.spec) -> :hide_value
      true -> :keep
    end
  end

  @doc false
  @spec place?(map(), map()) :: boolean()

  def place?(%{personal: true}, _ctx), do: true
  def place?(%{spec: spec}, _ctx), do: personal_spec?(spec)

  # ---

  defp personal_spec?({:personal, _inner}), do: true
  defp personal_spec?({:prim, mod}), do: mod.__domain_personal__()
  defp personal_spec?(_spec), do: false

  defp nested_place?({:prim, mod}), do: mod.__domain_personal__()
  defp nested_place?({:personal, _inner}), do: true
  defp nested_place?(spec), do: Enum.any?(values(spec), &nested_place?/1)

  defp values({kind, inner}) when kind in ~w(list set)a, do: [inner]
  defp values({:map, _key, value}), do: [value]
  defp values(_spec), do: []
end
