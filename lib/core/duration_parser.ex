defmodule Core.DurationParser do
  @moduledoc """
  Парсер строк длительности вида "30ms", "20s", "5m20s", "1h30m5s".

  `parse/3` отдаёт целое число в выбранной единице, `to_duration/2` — `Duration.t()`,
  `to_timeout/2` — OTP-таймаут (всегда целые миллисекунды).

  Семантика:

  - результат всегда неотрицательное целое: дробный ввод допустим, дробный вывод — нет;
  - строка обязана целиком состоять из токенов `<число><единица>` (пробелы вокруг и между
    токенами допустимы); голое число без единицы — `:invalid_format`;
  - арифметика точная (целые наносекунды), округление применяется однажды — к итоговой сумме,
    а не к отдельным токенам;
  - политика округления — опция `rounding: :no | :trunc | :ceil | :round` (по умолчанию `:no`:
    неточная конвертация даёт `%Error{code: :precision_loss}`).

  Отличие от `Kernel.to_timeout/1`: `to_timeout("500us")` возвращает ошибку, а не `0` —
  усечение запрашивается явным `rounding: :trunc`. По входу `to_timeout/2` — надмножество
  `Kernel.to_timeout/1`: строка, целое число миллисекунд, `:infinity`, `Duration.t()` и
  keyword-компоненты.
  """

  import Core.Helper.String, only: [first_line: 1]
  import Core.Guard

  alias Core.Error
  alias Core.Result

  require Error

  @token_regex ~r/(\d+)(?:\.(\d+))?\s*(ms|us|ns|d|h|m|s)/
  @format_regex ~r/^(?:\s*\d+(?:\.\d+)?\s*(?:ms|us|ns|d|h|m|s))+\s*$/

  @ns_per_us 1_000
  @ns_per_ms 1_000 * @ns_per_us
  @ns_per_s 1_000 * @ns_per_ms
  @ns_per_m 60 * @ns_per_s
  @ns_per_h 60 * @ns_per_m
  @ns_per_d 24 * @ns_per_h
  @ns_per_week 7 * @ns_per_d

  @us_per_s 1_000_000
  @us_per_m 60 * @us_per_s
  @us_per_h 60 * @us_per_m
  @us_per_d 24 * @us_per_h

  defmodule Unit do
    @moduledoc """
    Единица измерения длительности.

    | Значение | Описание |
    |---|---|
    | `:d` | сутки |
    | `:h` | часы |
    | `:m` | минуты |
    | `:s` | секунды |
    | `:ms` | миллисекунды |
    | `:us` | микросекунды |
    | `:ns` | наносекунды |
    """

    use Core.Enum,
      name: first_line(@moduledoc),
      values: ~w(d h m s ms us ns)a
  end

  defmodule Rounding do
    @moduledoc """
    Политика округления при конвертации в единицу результата.

    | Значение | Описание |
    |---|---|
    | `:no` | конвертация обязана быть точной, остаток — ошибка |
    | `:trunc` | отбросить дробную часть |
    | `:ceil` | округлить вверх |
    | `:round` | округлить к ближайшему |
    """

    use Core.Enum,
      name: first_line(@moduledoc),
      values: ~w(no trunc ceil round)a
  end

  @typedoc "Вход `to_timeout/2`: надмножество `Kernel.to_timeout/1`."
  @type timeout_input ::
          String.t() | non_neg_integer() | :infinity | Duration.t() | keyword(integer())

  @doc """
  Парсит строку длительности, возвращает целое значение в единице `unit` (по умолчанию `:s`).

  Опции: `rounding: :no | :trunc | :ceil | :round` (по умолчанию `:no`).
  """
  @spec parse(String.t(), Unit.t(), keyword()) :: {:ok, non_neg_integer()} | {:error, Error.t()}

  def parse(str, unit \\ :s, opts \\ []) when is_binary(str) and is_enum(unit, Unit) do
    rounding = rounding!(opts)

    with {:ok, ns} <- string_to_ns(str),
         do: convert(ns, unit, rounding, str)
  end

  @doc "Как `parse/3`, но поднимает исключение при ошибке."
  @spec parse!(String.t(), Unit.t(), keyword()) :: non_neg_integer()

  def parse!(str, unit \\ :s, opts \\ []), do: Result.unwrap!(parse(str, unit, opts))

  @doc """
  Парсит строку длительности в `Duration.t()` (day / hour / minute / second / microsecond).

  Опции — как у `parse/3`; точность `Duration` — микросекунда.
  """
  @spec to_duration(String.t(), keyword()) :: {:ok, Duration.t()} | {:error, Error.t()}

  def to_duration(str, opts \\ []) when is_binary(str) do
    rounding = rounding!(opts)

    with {:ok, {num, den}} <- string_to_ns(str),
         {:ok, us} <- divide(num, den * @ns_per_us, rounding, str, :us) do
      {:ok, microseconds_to_duration(us)}
    end
  end

  @doc "Как `to_duration/2`, но поднимает исключение при ошибке."
  @spec to_duration!(String.t(), keyword()) :: Duration.t()

  def to_duration!(str, opts \\ []), do: Result.unwrap!(to_duration(str, opts))

  @doc """
  OTP-таймаут в целых миллисекундах.

  Принимает строку длительности, целое число миллисекунд, `:infinity`, `Duration.t()` или
  keyword-компоненты (`week` / `day` / `hour` / `minute` / `second` / `millisecond` /
  `microsecond` / `nanosecond`). Повторяющиеся компоненты keyword суммируются (у
  `Kernel.to_timeout/1` — `ArgumentError`).

  Опции — как у `parse/3`.
  """
  @spec to_timeout(timeout_input(), keyword()) ::
          {:ok, non_neg_integer() | :infinity} | {:error, Error.t()}

  def to_timeout(input, opts \\ []), do: timeout(input, rounding!(opts))

  @doc "Как `to_timeout/2`, но поднимает исключение при ошибке."
  @spec to_timeout!(timeout_input(), keyword()) :: non_neg_integer() | :infinity

  def to_timeout!(input, opts \\ []), do: Result.unwrap!(__MODULE__.to_timeout(input, opts))

  # ---

  defp timeout(:infinity, _rounding), do: {:ok, :infinity}

  defp timeout(ms, _rounding) when is_integer(ms) and ms >= 0, do: {:ok, ms}

  defp timeout(str, rounding) when is_binary(str) do
    with {:ok, ns} <- string_to_ns(str),
         do: convert(ns, :ms, rounding, str)
  end

  defp timeout(%Duration{} = duration, rounding) do
    with {:ok, ns} <- duration_to_ns(duration),
         do: convert({ns, 1}, :ms, rounding, duration)
  end

  defp timeout(components, rounding) when is_list(components) do
    if Keyword.keyword?(components),
      do: keyword_timeout(components, rounding),
      else: {:error, invalid_input_error(components)}
  end

  # Контракт модуля — `{:error, %Error{}}`: отрицательное число, float и прочий мусор
  # обязаны приходить ошибкой, а не `FunctionClauseError` из середины парсера.
  defp timeout(ms, _rounding) when is_integer(ms), do: {:error, negative_duration_error(ms)}

  defp timeout(other, _rounding), do: {:error, invalid_input_error(other)}

  defp keyword_timeout(components, rounding) do
    with {:ok, ns} <- components_to_ns(components),
         do: convert({ns, 1}, :ms, rounding, components)
  end

  defp rounding!(opts) do
    opts
    |> Keyword.validate!(rounding: :no)
    |> Keyword.fetch!(:rounding)
    |> checked_rounding()
  end

  defp checked_rounding(rounding) when is_enum(rounding, Rounding), do: rounding

  defp string_to_ns(str) do
    downcased = String.downcase(str)

    if Regex.match?(@format_regex, downcased),
      do: {:ok, scan_ns(downcased)},
      else: {:error, invalid_format_error(str)}
  end

  defp scan_ns(str) do
    @token_regex
    |> Regex.scan(str)
    |> Enum.reduce({0, 1}, fn token, acc -> add_fractions(acc, token_ns(token)) end)
  end

  defp token_ns([_match, int_str, "", unit_str]),
    do: {String.to_integer(int_str) * ns_per_token(unit_str), 1}

  defp token_ns([_match, int_str, frac_str, unit_str]) do
    den = Integer.pow(10, byte_size(frac_str))
    num = String.to_integer(int_str) * den + String.to_integer(frac_str)

    {num * ns_per_token(unit_str), den}
  end

  defp add_fractions({num1, den}, {num2, den}), do: {num1 + num2, den}

  defp add_fractions({num1, den1}, {num2, den2}),
    do: reduce_fraction({num1 * den2 + num2 * den1, den1 * den2})

  defp reduce_fraction({num, den}) do
    case Integer.gcd(num, den) do
      1 -> {num, den}
      gcd -> {div(num, gcd), div(den, gcd)}
    end
  end

  defp duration_to_ns(%Duration{year: 0, month: 0} = duration) do
    %Duration{week: week, day: day, hour: hour, minute: minute, second: second} = duration
    {us, _precision} = duration.microsecond

    ns =
      week * @ns_per_week + day * @ns_per_d + hour * @ns_per_h +
        minute * @ns_per_m + second * @ns_per_s + us * @ns_per_us

    if ns < 0,
      do: {:error, negative_duration_error(duration)},
      else: {:ok, ns}
  end

  defp duration_to_ns(%Duration{} = duration),
    do: {:error, unsupported_component_error(duration)}

  defp components_to_ns(components) do
    with {:ok, ns} <- sum_components(components) do
      if ns < 0,
        do: {:error, negative_duration_error(components)},
        else: {:ok, ns}
    end
  end

  defp sum_components(components) do
    Enum.reduce_while(components, {:ok, 0}, fn {key, value}, {:ok, acc} ->
      case component_ns(key, value) do
        {:ok, ns} -> {:cont, {:ok, acc + ns}}
        {:error, _error} = err -> {:halt, err}
      end
    end)
  end

  defp component_ns(:week, value) when is_integer(value), do: {:ok, value * @ns_per_week}
  defp component_ns(:day, value) when is_integer(value), do: {:ok, value * @ns_per_d}
  defp component_ns(:hour, value) when is_integer(value), do: {:ok, value * @ns_per_h}
  defp component_ns(:minute, value) when is_integer(value), do: {:ok, value * @ns_per_m}
  defp component_ns(:second, value) when is_integer(value), do: {:ok, value * @ns_per_s}
  defp component_ns(:millisecond, value) when is_integer(value), do: {:ok, value * @ns_per_ms}
  defp component_ns(:microsecond, value) when is_integer(value), do: {:ok, value * @ns_per_us}
  defp component_ns(:nanosecond, value) when is_integer(value), do: {:ok, value}
  defp component_ns(key, value), do: {:error, invalid_component_error(key, value)}

  defp convert({num, den}, unit, rounding, input),
    do: divide(num, den * ns_per(unit), rounding, input, unit)

  defp divide(num, den, :no, input, unit) do
    if rem(num, den) == 0,
      do: {:ok, div(num, den)},
      else: {:error, precision_loss_error(input, unit)}
  end

  defp divide(num, den, :trunc, _input, _unit), do: {:ok, div(num, den)}
  defp divide(num, den, :ceil, _input, _unit), do: {:ok, div(num + den - 1, den)}
  defp divide(num, den, :round, _input, _unit), do: {:ok, div(2 * num + den, 2 * den)}

  defp microseconds_to_duration(total_us) do
    {days, total_us} = {div(total_us, @us_per_d), rem(total_us, @us_per_d)}
    {hours, total_us} = {div(total_us, @us_per_h), rem(total_us, @us_per_h)}
    {minutes, total_us} = {div(total_us, @us_per_m), rem(total_us, @us_per_m)}
    {seconds, microsecond} = {div(total_us, @us_per_s), rem(total_us, @us_per_s)}

    Duration.new!(
      day: days,
      hour: hours,
      minute: minutes,
      second: seconds,
      microsecond: microsecond_component(microsecond)
    )
  end

  defp microsecond_component(0), do: {0, 0}
  defp microsecond_component(us), do: {us, 6}

  defp ns_per(:d), do: @ns_per_d
  defp ns_per(:h), do: @ns_per_h
  defp ns_per(:m), do: @ns_per_m
  defp ns_per(:s), do: @ns_per_s
  defp ns_per(:ms), do: @ns_per_ms
  defp ns_per(:us), do: @ns_per_us
  defp ns_per(:ns), do: 1

  defp ns_per_token("d"), do: @ns_per_d
  defp ns_per_token("h"), do: @ns_per_h
  defp ns_per_token("m"), do: @ns_per_m
  defp ns_per_token("s"), do: @ns_per_s
  defp ns_per_token("ms"), do: @ns_per_ms
  defp ns_per_token("us"), do: @ns_per_us
  defp ns_per_token("ns"), do: 1

  defp invalid_format_error(input) do
    Error.domain(
      code: :invalid_format,
      ns: :duration_parser,
      message: "строка не является корректной длительностью: #{inspect(input)}",
      detail: input
    )
  end

  defp precision_loss_error(input, unit) do
    Error.domain(
      code: :precision_loss,
      ns: :duration_parser,
      message: "длительность #{inspect(input)} не выражается целым числом в единице #{unit}",
      detail: {input, unit}
    )
  end

  defp unsupported_component_error(%Duration{} = duration) do
    Error.domain(
      code: :unsupported_component,
      ns: :duration_parser,
      message: "длительность с ненулевым year/month не конвертируется: #{inspect(duration)}",
      detail: duration
    )
  end

  defp invalid_component_error(key, value) do
    Error.domain(
      code: :invalid_component,
      ns: :duration_parser,
      message: "недопустимый компонент длительности: #{inspect(key)}",
      detail: {key, value}
    )
  end

  defp invalid_input_error(input) do
    Error.domain(
      code: :invalid_input,
      ns: :duration_parser,
      message: "недопустимое значение длительности: #{inspect(input)}",
      detail: input
    )
  end

  defp negative_duration_error(input) do
    Error.domain(
      code: :negative_duration,
      ns: :duration_parser,
      message: "длительность должна быть неотрицательной: #{inspect(input)}",
      detail: input
    )
  end
end
