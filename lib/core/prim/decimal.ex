defmodule Core.Prim.Decimal do
  @moduledoc """
  Билдер decimal-Prim поверх `Decimal`.

  Опции: `name:` (обязательна), `kind:`, `min:`, `max:`, `scale:`, `mutate:` /
  `validate:`, `sensitive:`. Не-финитные значения (`NaN`, `Infinity`) отбраковываются
  на `cast`: сравнения над ними поднимают `Decimal.Error` мимо контракта `new/1`.
  """

  alias Core.Helper
  alias Core.Prim
  alias Core.Validator

  @native_kind :decimal
  @required_keys ~w(name)a
  @optional_keys ~w(kind min max scale mutate validate sensitive)a

  @doc "Объявить decimal-Prim (`name:` + опции min/max/scale)."
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      Helper.Opts.validate!(
        opts,
        Core.Prim.Decimal.required_keys(),
        Core.Prim.Decimal.optional_keys(),
        "Prim.Decimal"
      )

      native = Core.Prim.Decimal.native_kind()
      kind = Keyword.get(opts, :kind, native)
      Prim.validate_kind!(native, kind)

      type_opts = Keyword.take(opts, ~w(min max scale)a)

      use Prim,
        cast: &Core.Prim.Decimal.cast/1,
        validate: {Validator.Decimal, type_opts},
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
  @spec cast(term()) :: {:ok, Decimal.t()} | {:error, {:invalid_decimal, String.t()}}

  def cast(%Decimal{} = value), do: finite(value)

  def cast(value) when is_integer(value) do
    {:ok, Decimal.new(value)}
  end

  def cast(value) when is_float(value) do
    {:ok, Decimal.from_float(value)}
  end

  def cast(value) when is_binary(value) do
    finite(Decimal.new(value))
  rescue
    Decimal.Error -> {:error, {:invalid_decimal, "невалидное значение"}}
  end

  def cast(_), do: {:error, {:invalid_decimal, "невалидное значение"}}

  # ---

  # `Decimal.new/1` парсит "NaN" / "Infinity" / "-inf" без исключения, а `Decimal.compare/2`
  # на таком значении поднимает `Decimal.Error` (traps дефолтного контекста) уже внутри
  # валидатора — в обход контракта `{:ok, t()} | {:error, _}`.
  defp finite(%Decimal{} = value) do
    if Decimal.nan?(value) or Decimal.inf?(value),
      do: {:error, {:invalid_decimal, "невалидное значение"}},
      else: {:ok, value}
  end
end
