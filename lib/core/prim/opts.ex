defmodule Core.Prim.Opts do
  @moduledoc """
  Compile-time проверка **значений** опций Prim-обёрток.

  `Core.Helper.Opts` проверяет набор ключей, этот модуль — их значения: границу,
  регулярку, таймзону, версию UUID. Ошибка в опции обязана падать `CompileError`
  на `use`, потому что в рантайме она приходит доменной ошибкой первого `new/1`,
  где неотличима от невалидного пользовательского ввода.
  """

  alias Core.Helper
  alias Core.Prim

  @tz_shape ~r{^[A-Za-z][A-Za-z0-9+\-_]*(/[A-Za-z0-9+\-_]+)*$}

  @doc """
  Проверить опции `use` обёртки и вернуть её `kind`.

  Порядок один на все обёртки: набор ключей → `kind:` → значения опций
  (`validate_opts!/1` самой обёртки). Метаданные берутся из `Core.Prim.Wrapper`,
  поэтому копиям пролога негде разъехаться.
  """
  @spec prepare!(keyword(), module()) :: atom()

  def prepare!(opts, wrapper) when is_list(opts) and is_atom(wrapper) do
    label = wrapper.label()

    Helper.Opts.validate!(opts, wrapper.required_keys(), wrapper.optional_keys(), label)
    kind = kind!(opts, wrapper.native_kind(), label)
    wrapper.validate_opts!(opts)

    kind
  end

  @doc "Резолв и проверка `kind:`: свой атом либо native обёртки."
  @spec kind!(keyword(), atom(), String.t()) :: atom()

  def kind!(opts, native, label) when is_list(opts) and is_atom(native) do
    case Keyword.get(opts, :kind, native) do
      kind when is_atom(kind) ->
        Prim.validate_kind!(native, kind)
        kind

      other ->
        bad!(label, :kind, "атом", other)
    end
  end

  @doc "Проверить boolean-опции (`nil` — опция не задана)."
  @spec boolean!(keyword(), [atom()], String.t()) :: :ok

  def boolean!(opts, keys, label) do
    each_given(opts, keys, label, "true или false", &is_boolean/1)
  end

  @doc "Проверить целые неотрицательные опции."
  @spec non_neg_integer!(keyword(), [atom()], String.t()) :: :ok

  def non_neg_integer!(opts, keys, label) do
    each_given(opts, keys, label, "целое ≥ 0", &(is_integer(&1) and &1 >= 0))
  end

  @doc "Проверить, что значение опции — одно из `allowed`."
  @spec allowed!(keyword(), atom(), [term()], String.t()) :: :ok

  def allowed!(opts, key, allowed, label) do
    if Keyword.has_key?(opts, key) and Keyword.get(opts, key) not in allowed do
      bad!(label, key, "одно из #{inspect(allowed)}", Keyword.get(opts, key))
    end

    :ok
  end

  @doc "Проверить, что опция — `%Regex{}`."
  @spec regex!(keyword(), atom(), String.t()) :: :ok

  def regex!(opts, key, label) do
    each_given(opts, [key], label, "%Regex{} (`~r/.../`)", &is_struct(&1, Regex))
  end

  @doc "Проверить целочисленные границы и их порядок (`min` ≤ `max`)."
  @spec int_bounds!(keyword(), atom(), atom(), String.t()) :: :ok

  def int_bounds!(opts, min_key, max_key, label) do
    each_given(opts, [min_key, max_key], label, "целое", &is_integer/1)
    order!(opts, min_key, max_key, label, &compare_number/2)
  end

  @doc "Проверить границы-struct (`%Date{}` / `%DateTime{}`) и их порядок."
  @spec struct_bounds!(keyword(), atom(), atom(), module(), String.t()) :: :ok

  def struct_bounds!(opts, min_key, max_key, mod, label) do
    each_given(opts, [min_key, max_key], label, "%#{inspect(mod)}{}", &is_struct(&1, mod))
    order!(opts, min_key, max_key, label, &mod.compare/2)
  end

  @doc "Проверить границы `Decimal` (число, строка или `%Decimal{}`) и их порядок."
  @spec decimal_bounds!(keyword(), atom(), atom(), String.t()) :: :ok

  def decimal_bounds!(opts, min_key, max_key, label) do
    each_given(opts, [min_key, max_key], label, "число, строку или %Decimal{}", &decimal?/1)
    order!(opts, min_key, max_key, label, &compare_decimal/2)
  end

  @doc """
  Проверить IANA-таймзону.

  tz-база не поднимается на этапе компиляции (`ensure_all_started(:tzdata)` тянул бы
  чтение базы внутрь компилятора): если она уже доступна — зона проверяется полностью,
  иначе только форма имени.
  """
  @spec tz!(keyword(), atom(), String.t()) :: :ok

  def tz!(opts, key, label) do
    case Keyword.get(opts, key) do
      nil -> :ok
      tz when is_binary(tz) -> known_tz!(tz, label, key)
      other -> bad!(label, key, "строку IANA-зоны", other)
    end
  end

  @doc false
  @spec to_decimal(Decimal.t() | integer() | float() | binary()) :: Decimal.t()

  def to_decimal(%Decimal{} = value), do: value
  def to_decimal(value) when is_integer(value), do: Decimal.new(value)
  def to_decimal(value) when is_float(value), do: Decimal.from_float(value)
  def to_decimal(value) when is_binary(value), do: Decimal.new(value)

  # ---

  defp known_tz!(tz, label, key) do
    case DateTime.shift_zone(DateTime.utc_now(), tz) do
      {:ok, _shifted} -> :ok
      {:error, :time_zone_not_found} -> bad!(label, key, "известную IANA-зону", tz)
      {:error, _no_tz_database} -> tz_shape!(tz, label, key)
    end
  end

  defp tz_shape!(tz, label, key) do
    if Regex.match?(@tz_shape, tz),
      do: :ok,
      else: bad!(label, key, "известную IANA-зону", tz)
  end

  defp each_given(opts, keys, label, expected, valid?) do
    Enum.each(keys, fn key ->
      value = Keyword.get(opts, key)

      if not is_nil(value) and not valid?.(value) do
        bad!(label, key, expected, value)
      end
    end)
  end

  defp order!(opts, min_key, max_key, label, compare) do
    min = Keyword.get(opts, min_key)
    max = Keyword.get(opts, max_key)

    if not is_nil(min) and not is_nil(max) and compare.(min, max) == :gt do
      raise CompileError,
        description:
          "#{label}: #{min_key} (#{inspect(min)}) больше #{max_key} (#{inspect(max)}) — " <>
            "такой Prim не примет ни одного значения"
    end

    :ok
  end

  defp compare_number(left, right) when left < right, do: :lt
  defp compare_number(left, right) when left > right, do: :gt
  defp compare_number(_left, _right), do: :eq

  defp compare_decimal(left, right), do: Decimal.compare(to_decimal(left), to_decimal(right))

  defp decimal?(value) when is_integer(value) or is_float(value), do: true
  defp decimal?(%Decimal{} = value), do: not (Decimal.nan?(value) or Decimal.inf?(value))

  defp decimal?(value) when is_binary(value) do
    match?({%Decimal{}, ""}, Decimal.parse(value)) and decimal?(Decimal.new(value))
  end

  defp decimal?(_value), do: false

  defp bad!(label, key, expected, value) do
    raise CompileError,
      description: "#{label}: #{key}: ожидается #{expected}, получено: #{inspect(value)}"
  end
end
