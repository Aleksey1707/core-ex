defmodule Core.Web.Prefer do
  @moduledoc """
  Заголовок `Prefer` (RFC 7240): готов ли клиент ждать ответа, пока сервер доделывает работу после
  записи — у команды event-sourced агрегата это ожидание проекции.

  Понимает два предпочтения, остальные игнорирует:

  | Предпочтение | Смысл |
  |---|---|
  | `respond-async` | ответить сразу, не дожидаясь |
  | `wait=N` | ждать не дольше `N` секунд; `wait=0` — как `respond-async` |

  `N` — целое или десятичная дробь (`0.2`): это шире RFC 7240, где `wait` только целый. Точность —
  миллисекунда, разряды дальше округляются вверх: положительное `N` не становится нулём.

  Предпочтение — подсказка, а не требование: неразборчивое значение игнорируется без ошибки, из
  повторов учитывается только первое, даже неразборчивое (RFC 7240, раздел 2). Сервер урезает
  `wait=N` до своего предела и сообщает применённое заголовком `Preference-Applied` (`applied/3`).

  Значения заголовков — `Plug.Conn.get_req_header(conn, "prefer")`.
  """

  @enforce_keys [:respond_async, :wait_ms]
  defstruct @enforce_keys

  @type t :: %__MODULE__{respond_async: boolean(), wait_ms: non_neg_integer() | nil}

  @typedoc "Ждать до `pos_integer()` мс либо ответить сразу."
  @type mode :: :respond_async | {:wait, pos_integer()}

  # ===== разбор =====

  @doc "Разобрать значения заголовков `Prefer`; без заголовка — пустые предпочтения."
  @spec parse([String.t()]) :: t()

  def parse(values) when is_list(values) do
    preferences =
      values
      |> Enum.flat_map(&split_unquoted(&1, ?,))
      |> Enum.map(&preference/1)
      |> Enum.uniq_by(fn {token, _value} -> token end)
      |> Map.new()

    %__MODULE__{
      respond_async: Map.has_key?(preferences, "respond-async"),
      wait_ms: parse_wait(Map.get(preferences, "wait"))
    }
  end

  # ---

  defp preference(raw) do
    [pref | _params] = split_unquoted(raw, ?;)

    case String.split(pref, "=", parts: 2) do
      [token] -> {String.downcase(String.trim(token)), nil}
      [token, value] -> {String.downcase(String.trim(token)), unquote_value(String.trim(value))}
    end
  end

  defp parse_wait(value) when is_binary(value) do
    case Regex.run(~r/\A(\d+)(?:\.(\d+))?\z/, value, capture: :all_but_first) do
      [seconds | fraction] -> String.to_integer(seconds) * 1_000 + fraction_ms(fraction)
      nil -> nil
    end
  end

  defp parse_wait(nil), do: nil

  defp fraction_ms([]), do: 0

  defp fraction_ms([fraction]) do
    {ms, rest} = String.split_at(String.pad_trailing(fraction, 3, "0"), 3)

    case String.trim_trailing(rest, "0") do
      "" -> String.to_integer(ms)
      _below_ms -> String.to_integer(ms) + 1
    end
  end

  defp unquote_value(<<?", rest::binary>> = value) do
    case String.split_at(rest, -1) do
      {inner, "\""} -> inner
      _unclosed -> value
    end
  end

  defp unquote_value(value), do: value

  defp split_unquoted(value, separator), do: split_unquoted(value, separator, false, "", [])

  defp split_unquoted(<<>>, _separator, _quoted?, part, parts), do: Enum.reverse([part | parts])

  defp split_unquoted(<<?\\, char, rest::binary>>, separator, true, part, parts),
    do: split_unquoted(rest, separator, true, <<part::binary, ?\\, char>>, parts)

  defp split_unquoted(<<?", rest::binary>>, separator, quoted?, part, parts),
    do: split_unquoted(rest, separator, not quoted?, <<part::binary, ?">>, parts)

  defp split_unquoted(<<separator, rest::binary>>, separator, false, part, parts),
    do: split_unquoted(rest, separator, false, "", [part | parts])

  defp split_unquoted(<<char, rest::binary>>, separator, quoted?, part, parts),
    do: split_unquoted(rest, separator, quoted?, <<part::binary, char>>, parts)

  # ===== применение =====

  @doc """
  Режим ответа при серверном пределе ожидания `max_ms`.

  Без предпочтений — ожидание с пределом; `wait=N` — `min(N с, max_ms)`; `respond-async` без `wait`
  и `wait=0` — `:respond_async`.
  """
  @spec mode(t(), pos_integer()) :: mode()

  def mode(%__MODULE__{respond_async: async?, wait_ms: wait_ms}, max_ms) when is_integer(max_ms) and max_ms > 0 do
    case wait_ms do
      0 -> :respond_async
      nil when async? -> :respond_async
      nil -> {:wait, max_ms}
      ms -> {:wait, min(ms, max_ms)}
    end
  end

  @doc """
  Значение `Preference-Applied` при пределе `max_ms` и итоговом статусе; без применённого — `nil`.

  `respond-async` применён только при ответе 202: дождавшийся ответ 200 асинхронным не был.
  `wait` — применённое значение в секундах, урезанное до предела: дробь до миллисекунды без хвостовых
  нулей (`wait=0.05`), целое — без точки.
  """
  @spec applied(t(), pos_integer(), 200 | 202) :: String.t() | nil

  def applied(%__MODULE__{respond_async: async?, wait_ms: wait_ms}, max_ms, status)
      when is_integer(max_ms) and max_ms > 0 and status in [200, 202] do
    case applied_tokens(async? and status == 202, wait_ms, max_ms) do
      [] -> nil
      tokens -> Enum.join(tokens, ", ")
    end
  end

  # ---

  defp applied_tokens(async?, wait_ms, max_ms) do
    Enum.filter(
      [async? && "respond-async", wait_ms && "wait=#{format_seconds(min(wait_ms, max_ms))}"],
      &is_binary/1
    )
  end

  defp format_seconds(ms) do
    case rem(ms, 1_000) do
      0 -> Integer.to_string(div(ms, 1_000))
      fraction_ms -> "#{div(ms, 1_000)}.#{format_fraction(fraction_ms)}"
    end
  end

  defp format_fraction(fraction_ms) do
    fraction_ms
    |> Integer.to_string()
    |> String.pad_leading(3, "0")
    |> String.trim_trailing("0")
  end
end
