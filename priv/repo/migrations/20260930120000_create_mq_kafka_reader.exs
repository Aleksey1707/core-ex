defmodule Core.TestRepo.Migrations.CreateMqKafkaReader do
  @moduledoc """
  Таблицы смещений и аренды читателя Kafka; DDL — `Core.Mq.Kafka.Migration`.

  Ровно то же делегирование пишет у себя приложение-потребитель, поэтому тесты библиотеки
  гоняются против его схемы.
  """

  use Ecto.Migration

  defdelegate up, to: Core.Mq.Kafka.Migration
  defdelegate down, to: Core.Mq.Kafka.Migration
end
