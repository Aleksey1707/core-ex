defmodule Core.TestRepo.Migrations.CreateEsEvents do
  @moduledoc """
  Таблица хранилища событий; DDL — `Core.Es.Migration`.

  Ровно то же делегирование пишет у себя приложение-потребитель (README, «Что предоставляет
  потребитель»), поэтому тесты библиотеки гоняются против его схемы.
  """

  use Ecto.Migration

  defdelegate up, to: Core.Es.Migration
  defdelegate down, to: Core.Es.Migration
end
