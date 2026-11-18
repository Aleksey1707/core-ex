defmodule Core.Field.Meta.Default do
  @moduledoc false

  alias Core.Helper.Opts

  @spec key() :: atom()
  def key, do: :default

  @spec roles() :: [atom()]
  def roles, do: ~w(struct)a

  @spec normalize!(term(), map()) :: term()
  def normalize!(:none, _ctx), do: :none

  def normalize!({:default, %Core.Es.Personal.Destroyed{}}, %{where: where}) do
    Opts.reject!(
      "#{where}: default",
      "%Core.Es.Personal.Destroyed{} значением по умолчанию не бывает — уничтоженное значение не записывается"
    )
  end

  def normalize!({:default, value}, _ctx), do: {:default, value}

  def normalize!(raw, %{where: where}),
    do: Opts.reject!("#{where}: default", "ожидается :none или {:default, значение}, получено #{inspect(raw)}")

  @spec read_extra(map(), map()) :: :none | {:union, Macro.t()}
  def read_extra(_field, _ctx), do: :none

  @spec write_reject(map(), map()) :: :ok | {:reject, String.t()}
  def write_reject(_field, _ctx), do: :ok

  @spec plan_extra([atom()], map(), map()) :: [map()]
  def plan_extra(_path, _field, _ctx), do: []

  @spec inspect_policy(map(), map()) :: :keep | :hide_value | :hide_all
  def inspect_policy(_field, _ctx), do: :keep
end
