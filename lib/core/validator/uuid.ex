defmodule Core.Validator.UUID do
  @moduledoc """
  Валидатор UUID-строки: формат и (опционально) версия.
  """

  @behaviour Core.Validator

  @doc "Проверить UUID (опция `:version`)."
  @impl true
  def validate(value, opts) when is_binary(value) do
    expected_version = Keyword.get(opts, :version, 4)

    case UUID.info(value) do
      {:ok, info} ->
        version = Keyword.get(info, :version)

        if is_nil(expected_version) or version == expected_version do
          :ok
        else
          {:error, {:version, "неверная версия UUID (ожидалась #{expected_version})"}}
        end

      {:error, _} ->
        {:error, {:invalid_uuid, "невалидное значение"}}
    end
  end
end
