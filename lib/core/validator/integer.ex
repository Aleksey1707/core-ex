defmodule Core.Validator.Integer do
  @moduledoc """
  Валидатор целого: `min:` / `max:`.
  """

  @behaviour Core.Validator

  @doc "Проверить integer по опциям `:min` / `:max`."
  @impl true
  def validate(value, opts) when is_integer(value) do
    check_bounds(value, Keyword.get(opts, :min), Keyword.get(opts, :max))
  end

  # ---

  defp check_bounds(value, min, max) when is_integer(min) and is_integer(max) do
    if value >= min and value <= max do
      :ok
    else
      {:error, {:bounds, "от #{min} до #{max}"}}
    end
  end

  defp check_bounds(value, min, nil) when is_integer(min) do
    if value >= min do
      :ok
    else
      {:error, {:min, "минимум #{min}"}}
    end
  end

  defp check_bounds(value, nil, max) when is_integer(max) do
    if value <= max do
      :ok
    else
      {:error, {:max, "максимум #{max}"}}
    end
  end

  defp check_bounds(_value, nil, nil), do: :ok
end
