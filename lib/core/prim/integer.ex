defmodule Core.Prim.Integer do
  @moduledoc """
  Билдер integer-Prim: `min:` / `max:` через `Validator.Integer`.

  Опции: `name:` (обязательна), `kind:`, `min:`, `max:`, `mutate:` / `validate:`,
  `sensitive:`.
  """

  alias Core.Helper
  alias Core.Prim
  alias Core.Validator

  @native_kind :integer
  @required_keys ~w(name)a
  @optional_keys ~w(kind min max mutate validate sensitive)a

  @doc "Объявить integer-Prim (`name:` + опции min/max)."
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      Helper.Opts.validate!(
        opts,
        Core.Prim.Integer.required_keys(),
        Core.Prim.Integer.optional_keys(),
        "Prim.Integer"
      )

      native = Core.Prim.Integer.native_kind()
      kind = Keyword.get(opts, :kind, native)
      Prim.validate_kind!(native, kind)

      type_opts = Keyword.take(opts, ~w(min max)a)

      use Prim,
        cast: &Core.Prim.Integer.cast/1,
        validate: {Validator.Integer, type_opts},
        custom_mutate: Keyword.get(opts, :mutate),
        custom_validate: Keyword.get(opts, :validate),
        name: Keyword.fetch!(opts, :name),
        kind: kind,
        type_opts: type_opts,
        sensitive: Keyword.get(opts, :sensitive, false)
    end
  end

  @doc false
  @spec native_kind() :: atom()

  def native_kind, do: @native_kind

  @doc false
  @spec required_keys() :: [atom()]

  def required_keys, do: @required_keys

  @doc false
  @spec optional_keys() :: [atom()]

  def optional_keys, do: @optional_keys

  @doc false
  @spec cast(term()) :: {:ok, integer()} | {:error, {:invalid_integer, String.t()}}

  def cast(value) when is_integer(value), do: {:ok, value}

  def cast(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> {:ok, int}
      _ -> {:error, {:invalid_integer, "невалидное значение"}}
    end
  end

  def cast(_), do: {:error, {:invalid_integer, "невалидное значение"}}
end
