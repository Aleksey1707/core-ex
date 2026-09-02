defmodule Core.Validator.Decimal do
  @moduledoc """
  Валидатор Decimal: границы `min:` / `max:` и `scale:`.

  Сравнения — NaN-безопасные (`Decimal.lt?/2`, `Decimal.gt?/2`): `Decimal.compare/2`
  на не-финитном значении поднимает `Decimal.Error`.
  """

  @behaviour Core.Validator

  @doc "Проверить decimal по опциям `:min` / `:max` / `:scale`."
  @impl true
  def validate(%Decimal{} = value, opts) do
    with :ok <- check_bounds(value, Keyword.get(opts, :min), Keyword.get(opts, :max)) do
      check_scale(value, Keyword.get(opts, :scale))
    end
  end

  # ---

  defp check_bounds(_value, nil, nil), do: :ok

  defp check_bounds(value, min, nil) do
    min = to_decimal(min)

    if Decimal.lt?(value, min),
      do: {:error, {:min, "минимум #{Decimal.to_string(min)}"}},
      else: :ok
  end

  defp check_bounds(value, nil, max) do
    max = to_decimal(max)

    if Decimal.gt?(value, max),
      do: {:error, {:max, "максимум #{Decimal.to_string(max)}"}},
      else: :ok
  end

  defp check_bounds(value, min, max) do
    min = to_decimal(min)
    max = to_decimal(max)

    if Decimal.lt?(value, min) or Decimal.gt?(value, max),
      do: {:error, {:bounds, "от #{Decimal.to_string(min)} до #{Decimal.to_string(max)}"}},
      else: :ok
  end

  defp check_scale(_value, nil), do: :ok

  defp check_scale(value, scale) when is_integer(scale) and scale >= 0 do
    if Decimal.eq?(value, Decimal.round(value, scale)) do
      :ok
    else
      {:error, {:scale, "неверный масштаб (#{scale})"}}
    end
  end

  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n) when is_integer(n), do: Decimal.new(n)
  defp to_decimal(n) when is_float(n), do: Decimal.from_float(n)
  defp to_decimal(n) when is_binary(n), do: Decimal.new(n)
end
