defmodule Core.TestRepo.Migrations.CreateOutbox do
  @moduledoc """
  Таблица очереди outbox; DDL — `Core.Outbox.Migration`.

  Ровно то же делегирование пишет у себя приложение-потребитель (README, «Что предоставляет
  потребитель»), поэтому тесты библиотеки гоняются против его схемы.
  """

  use Ecto.Migration

  defdelegate up, to: Core.Outbox.Migration
  defdelegate down, to: Core.Outbox.Migration
end
