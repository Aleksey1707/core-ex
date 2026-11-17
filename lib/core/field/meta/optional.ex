defmodule Core.Field.Meta.Optional do
  @moduledoc false

  alias Core.Helper.Opts

  @spec key() :: atom()
  def key, do: :optional

  @spec roles() :: [atom()]
  def roles, do: ~w(struct payload plugin view labels)a

  @spec normalize!(term(), map()) :: term()
  def normalize!(raw, _ctx) when is_boolean(raw), do: raw

  def normalize!(raw, %{where: where}),
    do: Opts.reject!("#{where}: optional", "ожидается boolean, получено #{inspect(raw)}")

  @spec read_extra(map(), map()) :: :none | {:union, Macro.t()}
  def read_extra(_field, _ctx), do: :none

  @spec write_reject(map(), map()) :: :ok | {:reject, String.t()}
  def write_reject(_field, _ctx), do: :ok

  @spec plan_extra([atom()], map(), map()) :: [map()]
  def plan_extra(_path, _field, _ctx), do: []

  @spec inspect_policy(map(), map()) :: :keep | :hide_value | :hide_all
  def inspect_policy(_field, _ctx), do: :keep
end
