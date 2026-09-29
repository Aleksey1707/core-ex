defmodule Core.Web.Prefer do
  @moduledoc """
  Заголовок `Prefer` (RFC 7240): готов ли клиент ждать ответа, пока сервер доделывает работу после
  записи — у команды event-sourced агрегата это ожидание проекции.

  Понимает два предпочтения, остальные игнорирует:

  | Предпочтение | Смысл |
  |---|---|
  | `respond-async` | ответить сразу, не дожидаясь |
  | `wait=N` | ждать не дольше `N` секунд; `wait=0` — как `respond-async` |

  Предпочтение — подсказка, а не требование: неразборчивое значение игнорируется без ошибки, из
  повторов учитывается только первое, даже неразборчивое (RFC 7240, раздел 2). Сервер урезает
  `wait=N` до своего предела и сообщает применённое заголовком `Preference-Applied` (`applied/3`).

  Значения заголовков — `Plug.Conn.get_req_header(conn, "prefer")`.
  """

  @enforce_keys [:respond_async, :wait]
  defstruct @enforce_keys

  @type t :: %__MODULE__{respond_async: boolean(), wait: non_neg_integer() | nil}

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
      wait: parse_wait(Map.get(preferences, "wait"))
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

  defp parse_wait(value) do
    if is_binary(value) and value =~ ~r/\A\d+\z/,
      do: String.to_integer(value)
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

  def mode(%__MODULE__{respond_async: async?, wait: wait}, max_ms) when is_integer(max_ms) and max_ms > 0 do
    case wait do
      0 -> :respond_async
      nil when async? -> :respond_async
      nil -> {:wait, max_ms}
      seconds -> {:wait, min(seconds * 1_000, max_ms)}
    end
  end

  @doc """
  Значение `Preference-Applied` при пределе `max_ms` и итоговом статусе; без применённого — `nil`.

  `respond-async` применён только при ответе 202: дождавшийся ответ 200 асинхронным не был.
  `wait` — применённое значение в секундах: урезанное до предела, округлённого вверх.
  """
  @spec applied(t(), pos_integer(), 200 | 202) :: String.t() | nil

  def applied(%__MODULE__{respond_async: async?, wait: wait}, max_ms, status)
      when is_integer(max_ms) and max_ms > 0 and status in [200, 202] do
    case applied_tokens(async? and status == 202, wait, max_ms) do
      [] -> nil
      tokens -> Enum.join(tokens, ", ")
    end
  end

  # ---

  defp applied_tokens(async?, wait, max_ms) do
    Enum.filter(
      [async? && "respond-async", wait && "wait=#{min(wait, div(max_ms + 999, 1_000))}"],
      &is_binary/1
    )
  end
end
