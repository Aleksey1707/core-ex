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

  defp check_bounds(value, min_len, max_len)
       when is_integer(min_len) and is_integer(max_len) do
    length = String.length(value)

    if length >= min_len and length <= max_len do
      :ok
    else
      {:error, {:bounds, "от #{min_len} до #{max_len} символа(ов)"}}
    end
  end

  defp check_bounds(value, min_len, nil) when is_integer(min_len) do
    if String.length(value) >= min_len do
      :ok
    else
      {:error, {:min_len, "минимум #{min_len} символа(ов)"}}
    end
  end

  defp check_bounds(value, nil, max_len) when is_integer(max_len) do
    if String.length(value) <= max_len do
      :ok
    else
      {:error, {:max_len, "максимум #{max_len} символа(ов)"}}
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
end
