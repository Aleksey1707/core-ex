defmodule Core.Field.Meta.Subject do
  @moduledoc false

  alias Core.Helper.Opts

  @spec key() :: atom()
  def key, do: :subject

  @spec roles() :: [atom()]
  def roles, do: ~w(struct payload)a

  @spec normalize!(term(), map()) :: term()
  def normalize!(nil, _ctx), do: nil
  def normalize!(:aggregate_id, _ctx), do: :aggregate_id

  def normalize!({tag, name}, _ctx)
      when tag in ~w(payload local)a and is_atom(name) and name not in ~w(nil true false)a,
      do: {tag, name}

  def normalize!(name, %{role: :payload}) when is_atom(name) and name not in ~w(nil true false)a,
    do: {:payload, name}

  def normalize!(name, %{role: :struct}) when is_atom(name) and name not in ~w(nil true false)a, do: {:local, name}

  def normalize!(raw, %{where: where}) do
    Opts.reject!(
      "#{where}: subject",
      "ожидается :aggregate_id или имя поля нагрузки; вложенный адрес — {:payload, поле} или {:local, поле}, " <>
        "получено #{inspect(raw)}"
    )
  end

  @spec read_extra(map(), map()) :: :none | {:union, Macro.t()}
  def read_extra(_field, _ctx), do: :none

  @spec write_reject(map(), map()) :: :ok | {:reject, String.t()}
  def write_reject(_field, _ctx), do: :ok

  @spec plan_extra([atom()], map(), map()) :: [map()]
  def plan_extra(_path, _field, _ctx), do: []

  @spec inspect_policy(map(), map()) :: :keep | :hide_value | :hide_all
  def inspect_policy(_field, _ctx), do: :keep
end
