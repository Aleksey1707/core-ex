defmodule Core.Validator.String do
  @moduledoc """
  Валидатор строки: `min_len:` / `max_len:` (в графемах) и `re:`.
  """

  @behaviour Core.Validator

  @doc "Проверить строку по опциям `:min_len` / `:max_len` / `:re`."
  @impl true
  def validate(value, opts) when is_binary(value) do
    with :ok <- check_bounds(value, Keyword.get(opts, :min_len), Keyword.get(opts, :max_len)) do
      check_re(value, Keyword.get(opts, :re))
    end
  end

  # ---

  defp check_bounds(value, min_len, max_len) when is_integer(min_len) and is_integer(max_len) do
    length = String.length(value)

    cond do
      min_len == max_len and length == min_len ->
        :ok

      min_len == max_len ->
        {:error, {:bounds, "ровно #{with_symbols(min_len)}"}}

      length >= min_len and length <= max_len ->
        :ok

      true ->
        {:error, {:bounds, "от #{min_len} до #{max_len} #{range_symbols(max_len)}"}}
    end
  end

  defp check_bounds(value, min_len, nil) when is_integer(min_len) do
    if String.length(value) >= min_len do
      :ok
    else
      {:error, {:min_len, "минимум #{with_symbols(min_len)}"}}
    end
  end

  defp check_bounds(value, nil, max_len) when is_integer(max_len) do
    if String.length(value) <= max_len do
      :ok
    else
      {:error, {:max_len, "максимум #{with_symbols(max_len)}"}}
    end
  end

  defp check_bounds(_value, nil, nil), do: :ok

  defp check_re(_value, nil), do: :ok

  defp check_re(value, %Regex{} = re) do
    if Regex.match?(re, value) do
      :ok
    else
      {:error, {:re, "неверный формат"}}
    end
  end

  defp with_symbols(count), do: "#{count} #{symbols(count)}"

  defp symbols(count) when rem(count, 10) == 1 and rem(count, 100) != 11, do: "символ"
  defp symbols(count) when rem(count, 10) in 2..4 and rem(count, 100) not in 12..14, do: "символа"
  defp symbols(_count), do: "символов"

  # После «до» numeral стоит в родительном падеже: «до двух символов», «до одного символа».
  defp range_symbols(count) when rem(count, 10) == 1 and rem(count, 100) != 11, do: "символа"
  defp range_symbols(_count), do: "символов"
end
