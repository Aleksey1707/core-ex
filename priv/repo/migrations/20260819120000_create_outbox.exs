defmodule Core.TestRepo.Migrations.CreateOutbox do
  @moduledoc """
  Таблица очереди outbox.

  Схлопнутая версия цепочки миграций: базовая таблица, токен аренды (`lease_id`,
  fencing для `save_results`) и индексы очереди с tiebreaker по `id`. `created_at`
  ставится на каждое событие отдельно и может совпасть в пределах микросекунды —
  пара `(created_at, id)` (id — UUIDv7, монотонен) задаёт полный порядок доставки.

  Одновременно это исполняемая спецификация таблицы для приложений-потребителей:
  колонки и индексы обязаны совпадать, имена индексов — нет.
  """

  use Ecto.Migration

  def change do
    create table(:outbox, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :topic, :string, null: false
      add :key, :string, null: false
      add :name, :string, null: false
      add :payload, :map, null: false, default: %{}
      add :status, :string, null: false
      add :attempts, :integer, null: false, default: 0
      add :locked_until, :utc_datetime_usec
      add :lease_id, :binary_id
      add :errors, :jsonb, null: false, default: fragment("'[]'::jsonb")
      add :headers, :map
      add :created_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec
      add :published_at, :utc_datetime_usec
    end

    create index(:outbox, [:created_at, :id],
             name: :ix_outbox_new_ordered,
             where: "status = 'new'"
           )

    create index(:outbox, [:topic, :created_at, :id],
             name: :ix_outbox_new_topic_ordered,
             where: "status = 'new'"
           )

    create index(:outbox, [:locked_until, :created_at, :id],
             name: :ix_outbox_in_work_ordered,
             where: "status = 'in_work'"
           )

    create index(:outbox, [:topic, :locked_until, :created_at, :id],
             name: :ix_outbox_in_work_topic_ordered,
             where: "status = 'in_work'"
           )

    create index(:outbox, [:published_at],
             name: :ix_outbox_published,
             where: "status = 'published'"
           )
  end
end
