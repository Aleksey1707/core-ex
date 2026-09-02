defmodule Core.Validator.Date do
  @moduledoc """
  Валидатор даты: границы `after:` / `before:`.
  """

  @behaviour Core.Validator

  @doc "Проверить дату по опциям `:after` / `:before`."
  @impl true
  def validate(%Date{} = value, opts) do
    with :ok <- check_after(value, Keyword.get(opts, :after)) do
      check_before(value, Keyword.get(opts, :before))
    end
  end

  # ---

  defp check_after(_value, nil), do: :ok

  defp check_after(value, %Date{} = after_date) do
    case Date.compare(value, after_date) do
      :gt -> :ok
      :eq -> :ok
      :lt -> {:error, {:after, "слишком ранняя дата"}}
    end
  end

  defp check_before(_value, nil), do: :ok

  defp check_before(value, %Date{} = before_date) do
    case Date.compare(value, before_date) do
      :lt -> :ok
      :eq -> :ok
      :gt -> {:error, {:before, "слишком поздняя дата"}}
    end
  end
end
