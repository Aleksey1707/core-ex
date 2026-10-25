defmodule Core.Prim.Decimal do
  @moduledoc """
  Билдер decimal-Prim поверх `Decimal`.

  Опции: `name:` (обязательна), `kind:`, `min:`, `max:`, `scale:`, `sec_max_len:`,
  `mutate:` / `validate:`, `sensitive:`, `personal:`. Не-финитные значения (`NaN`, `Infinity`)
  отбраковываются на `cast`: сравнения над ними поднимают `Decimal.Error` мимо
  контракта `new/1`.

  `sec_max_len` — граница **в байтах** для строкового ввода, отсекающая его до
  `Decimal.new/1`: разбор строит коэффициент по всей длине строки, то есть время
  растёт вместе с вводом (миллион цифр — десятки миллисекунд занятого шедулера),
  а границы `min:` / `max:` проверяются уже после него. Default выводится из `max:`
  и `scale:`, а без `max:` — 64 байта.

  Опции-выражения (`docs/rules/20-agreements.md`, «Опции `use`»): `name:`, `mutate:`, `validate:`,
  `min:`, `max:` (`Decimal.new/1`) — проверяются в теле модуля;
  остальные опции — литералы.
  """

  alias Core.Helper
  alias Core.Prim
  alias Core.Result

  use Core.Prim.Wrapper,
    label: "Prim.Decimal",
    native_kind: :decimal,
    optional: ~w(min max scale sec_max_len)a,
    expression: ~w(min max)a

  # запас на знак, точку, ведущие нули и экспоненциальную запись
  @sec_max_len_slack 8
  @default_sec_max_len 64

  @doc "Объявить decimal-Prim (`name:` + опции min/max/scale)."
  defmacro __using__(opts) do
    opts = Prim.Opts.prepare!(opts, __CALLER__, __MODULE__)
    type_opts = Prim.Opts.quoted(Keyword.take(opts, ~w(min max scale)a), expression_keys())
    sec_max_len = Keyword.take(opts, [:sec_max_len])

    base_opts =
      Prim.Wrapper.base_opts(opts, label()) ++
        [
          cast: quote(do: &Core.Prim.Decimal.cast/2),
          validate: quote(do: {Core.Validator.Decimal, @prim_type_opts}),
          type_opts: quote(do: @prim_type_opts),
          pipeline_opts:
            quote(do: [sec_max_len: Core.Prim.Decimal.sec_max_len(unquote(sec_max_len) ++ @prim_type_opts)]),
          value_type: quote(do: Decimal.t())
        ]

    quote do
      @prim_type_opts Core.Prim.Decimal.type_opts!(unquote(type_opts), unquote(sec_max_len))

      use Core.Prim, unquote(base_opts)
    end
  end

  @doc "Проверить значения опций-литералов билдера при раскрытии `use`."
  @spec validate_opts!(keyword()) :: :ok

  def validate_opts!(opts) do
    Prim.Opts.non_neg_integer!(opts, ~w(scale sec_max_len)a, label())
  end

  @doc false
  @spec type_opts!(keyword(), keyword()) :: keyword()

  # Опции типа с вычисленными опциями-выражениями `min:` / `max:` — проверка в теле модуля.
  def type_opts!(type_opts, sec_max_len) do
    Prim.Opts.decimal_bounds!(type_opts, :min, :max, label())
    fits_bounds!(sec_max_len ++ type_opts)

    type_opts
  end

  @doc "Байтовая граница строкового ввода: явная `sec_max_len:` либо выведенная из границ."
  @spec sec_max_len(keyword()) :: pos_integer()

  def sec_max_len(type_opts) do
    Keyword.get(type_opts, :sec_max_len) || derived_sec_max_len(type_opts)
  end

  @doc false
  @spec cast(term()) :: Result.t(Decimal.t(), {:invalid_decimal, String.t()})

  # Арность 1 — для вызова без опций (read-путь кодека): значение оттуда уже разобрано.
  def cast(value), do: cast(value, [])

  @doc false
  @spec cast(term(), keyword()) :: Result.t(Decimal.t(), {:invalid_decimal, String.t()})

  def cast(%Decimal{} = value, _pipeline_opts), do: finite(value)

  def cast(value, _pipeline_opts) when is_integer(value) do
    {:ok, Decimal.new(value)}
  end

  def cast(value, _pipeline_opts) when is_float(value) do
    {:ok, Decimal.from_float(value)}
  end

  def cast(value, pipeline_opts) when is_binary(value) do
    with :ok <-
           Prim.check_byte_limit(value, Keyword.get(pipeline_opts, :sec_max_len), :invalid_decimal) do
      parse(value)
    end
  end

  def cast(_value, _pipeline_opts), do: invalid()

  # ---

  defp parse(value) do
    finite(Decimal.new(value))
  rescue
    Decimal.Error -> invalid()
  end

  defp invalid, do: {:error, {:invalid_decimal, "невалидное значение"}}

  # Явная граница, в которую не влезает собственный `max:`, отвергает валидные значения.
  defp fits_bounds!(opts) do
    limit = sec_max_len(opts)

    case bound_bytes(opts) do
      nil ->
        :ok

      bytes when bytes <= limit ->
        :ok

      bytes ->
        Helper.Opts.reject!(
          label(),
          "sec_max_len (#{limit}) меньше записи границ со scale (#{bytes} байт) — Prim не примет собственный max"
        )
    end
  end

  defp derived_sec_max_len(opts) do
    case bound_bytes(opts) do
      nil -> @default_sec_max_len
      bytes -> bytes + @sec_max_len_slack
    end
  end

  # Длину ввода ограничивает только верхняя граница: без `max:` любое число допустимо.
  # К целой части добавляется `scale:` — дробные разряды в записи значения.
  defp bound_bytes(opts) do
    case Keyword.get(opts, :max) do
      nil -> nil
      max -> digits(opts, max) + Keyword.get(opts, :scale, 0)
    end
  end

  defp digits(opts, max) do
    opts
    |> bounds(max)
    |> Enum.map(&byte_size(Decimal.to_string(Prim.Opts.to_decimal(&1), :normal)))
    |> Enum.max()
  end

  defp bounds(opts, max) do
    case Keyword.get(opts, :min) do
      nil -> [max]
      min -> [min, max]
    end
  end

  # `Decimal.new/1` парсит "NaN" / "Infinity" / "-inf" без исключения, а `Decimal.compare/2`
  # на таком значении поднимает `Decimal.Error` (traps дефолтного контекста) уже внутри
  # валидатора — в обход контракта `{:ok, t()} | {:error, _}`.
  defp finite(%Decimal{} = value) do
    if Decimal.nan?(value) or Decimal.inf?(value),
      do: {:error, {:invalid_decimal, "невалидное значение"}},
      else: {:ok, value}
  end
end
