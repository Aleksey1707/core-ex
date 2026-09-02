defmodule Core.Validator.DateTime do
  @moduledoc """
  Валидатор datetime: границы `after:` / `before:`.
  """

  @behaviour Core.Validator

  @doc "Проверить datetime по опциям `:after` / `:before`."
  @impl true
  def validate(%DateTime{} = value, opts) do
    with :ok <- check_after(value, Keyword.get(opts, :after)) do
      check_before(value, Keyword.get(opts, :before))
    end
  end

  # ---

  defp check_after(_value, nil), do: :ok

  defp check_after(value, %DateTime{} = after_dt) do
    case DateTime.compare(value, after_dt) do
      :gt -> :ok
      :eq -> :ok
      :lt -> {:error, {:after, "слишком ранняя дата"}}
    end
  end

  defp check_before(_value, nil), do: :ok

  defp check_before(value, %DateTime{} = before_dt) do
    case DateTime.compare(value, before_dt) do
      :lt -> :ok
      :eq -> :ok
      :gt -> {:error, {:before, "слишком поздняя дата"}}
    end
  end
end
