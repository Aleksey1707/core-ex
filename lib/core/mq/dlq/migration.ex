defmodule Core.Mq.Dlq.Migration do
  @moduledoc """
  DDL таблицы `mq_dlq` — DLQ подписчиков в Postgres (`Core.Mq.Dlq`), для миграции
  приложения-потребителя.

  Потребитель заводит миграцию со своим timestamp и делегирует DDL сюда:

      defmodule MyApp.Infra.DAO.Migrations.CreateMqDlq do
        use Ecto.Migration

        defdelegate up, to: Core.Mq.Dlq.Migration
        defdelegate down, to: Core.Mq.Dlq.Migration
      end

  Миграция самой библиотеки (`priv/repo/migrations`) делегирует сюда же.

  | Колонка | Значение |
  |---|---|
  | `id` | идентификатор записи — его принимает команда оператора `--id` |
  | `subscriber_name` | `subscriber_name:` writer'а: чей это DLQ |
  | `topic` | исходный топик сообщения (`x-dlq-source-topic`) |
  | `key` | ключ, байты; `NULL` — сообщение без ключа |
  | `header_names`, `header_values` | заголовки источника парами по индексу; значение — байты |
  | `body` | тело, байты; `NULL` — tombstone |
  | `source_partition`, `source_offset` | позиция в источнике; `NULL` — адаптер её не отдал |
  | `reason` | `rejected` / `exhausted` (`x-dlq-reason`) |
  | `error` | цепочка ошибки обработчика (`x-dlq-error`) |
  | `attempts` | число попыток обработки (`x-dlq-attempts`) |
  | `status` | `dead` → `requeued` → `processed` |
  | `lease_id`, `locked_until` | захват `requeued`-записи читателем |
  | `created_at`, `requeued_at`, `processed_at` | время выброса, возврата и обработки (часы Postgres) |

  Ключ, тело и значения заголовков — `bytea`: у записи чужого топика это байты не обязательно
  в UTF-8 (ADR-0032). Текст из них оператор получает `convert_from(body, 'UTF8')`.

  Колонки и значения `status` — контракт; имена индексов — нет.
  """

  use Ecto.Migration

  @doc "Создать таблицу DLQ и её индексы."
  @spec up() :: :ok

  def up do
    create table(:mq_dlq, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :subscriber_name, :text, null: false
      add :topic, :text, null: false
      add :key, :bytea
      add :header_names, {:array, :text}, null: false
      add :header_values, {:array, :bytea}, null: false
      add :body, :bytea
      add :source_partition, :integer
      add :source_offset, :bigint
      add :reason, :text
      add :error, :text
      add :attempts, :integer
      add :status, :text, null: false
      add :lease_id, :uuid
      add :locked_until, :timestamptz
      add :created_at, :timestamptz, null: false
      add :requeued_at, :timestamptz
      add :processed_at, :timestamptz
    end

    create index(:mq_dlq, [:topic, :id], name: :ix_mq_dlq_dead, where: "status = 'dead'")

    create index(:mq_dlq, [:subscriber_name, :topic, :id],
             name: :ix_mq_dlq_requeued,
             where: "status = 'requeued'"
           )

    :ok
  end

  @doc "Удалить таблицу DLQ; индексы уходят вместе с ней."
  @spec down() :: :ok

  def down do
    drop table(:mq_dlq)

    :ok
  end
end
