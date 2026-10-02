defmodule Core.Mq.Kafka.Migration do
  @moduledoc """
  DDL смещений и аренды `Core.Mq.Kafka.Reader` — для миграции приложения-потребителя.

  Потребитель заводит миграцию со своим timestamp и делегирует DDL сюда:

      defmodule MyApp.Infra.DAO.Migrations.CreateMqKafkaReader do
        use Ecto.Migration

        defdelegate up, to: Core.Mq.Kafka.Migration
        defdelegate down, to: Core.Mq.Kafka.Migration
      end

  Миграция самой библиотеки (`priv/repo/migrations`) делегирует сюда же. Модуль компилируется
  без клиента `:brod`: миграция у потребителя накатывается независимо от состава его `deps`.

  `mq_kafka_offsets` — следующее смещение, строка на партицию:

  | Колонка | Значение |
  |---|---|
  | `subscriber_name` | `subscriber_name:` читателя |
  | `topic` | топик Kafka |
  | `partition` | партиция |
  | `next_offset` | смещение, с которого чтение продолжится |
  | `updated_at` | время записи (часы Postgres) |

  `mq_kafka_leases` — аренда топика, строка на пару `(subscriber_name, topic)`: `lease_id` —
  fencing-токен владельца, `locked_until` — срок аренды по часам Postgres.

  Строку `mq_kafka_offsets` нельзя удалять вручную: без неё чтение партиции начнётся со
  стартовой позиции читателя, то есть по умолчанию — с начала топика (ADR-0033).

  Колонки и первичные ключи — контракт.
  """

  use Ecto.Migration

  @doc "Создать таблицы смещений и аренды."
  @spec up() :: :ok

  def up do
    create table(:mq_kafka_offsets, primary_key: false) do
      add :subscriber_name, :text, primary_key: true
      add :topic, :text, primary_key: true
      add :partition, :integer, primary_key: true
      add :next_offset, :bigint, null: false
      add :updated_at, :timestamptz, null: false
    end

    create table(:mq_kafka_leases, primary_key: false) do
      add :subscriber_name, :text, primary_key: true
      add :topic, :text, primary_key: true
      add :lease_id, :uuid, null: false
      add :locked_until, :timestamptz, null: false
      add :updated_at, :timestamptz, null: false
    end

    :ok
  end

  @doc "Удалить таблицы смещений и аренды."
  @spec down() :: :ok

  def down do
    drop table(:mq_kafka_leases)
    drop table(:mq_kafka_offsets)

    :ok
  end
end
