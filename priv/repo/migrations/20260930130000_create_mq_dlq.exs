defmodule Core.TestRepo.Migrations.CreateMqDlq do
  @moduledoc """
  Таблица DLQ подписчиков в Postgres; DDL — `Core.Mq.Dlq.Migration`.

  Ровно то же делегирование пишет у себя приложение-потребитель, поэтому тесты библиотеки
  гоняются против его схемы.
  """

  use Ecto.Migration

  defdelegate up, to: Core.Mq.Dlq.Migration
  defdelegate down, to: Core.Mq.Dlq.Migration
end
