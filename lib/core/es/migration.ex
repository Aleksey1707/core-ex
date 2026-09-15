defmodule Core.Es.Migration do
  @moduledoc """
  DDL хранилища событий, снапшотов и чекпоинтов проекций — для миграции приложения-потребителя;
  там же `delete_checkpoint/1` — строка чекпоинта проекции, убранной из кода.

  Потребитель заводит миграцию со своим timestamp и делегирует DDL сюда:

      defmodule MyApp.Repo.Migrations.CreateEsEvents do
        use Ecto.Migration

        defdelegate up, to: Core.Es.Migration
        defdelegate down, to: Core.Es.Migration
      end

  Миграция самой библиотеки (`priv/repo/migrations`) делегирует сюда же, поэтому у
  потребителя накатывается ровно та схема, против которой гоняются её тесты.

  `es_events` — события агрегатов обоих видов, одна таблица на приложение
  (`docs/adr/0008-shared-event-table-xid8-position.md`):

  | Колонка | Значение |
  |---|---|
  | `aggregate_type` | тип агрегата — `type:` кодека событий |
  | `aggregate_id` | идентификатор агрегата |
  | `aggregate_version` | версия агрегата |
  | `event_id` | идентификатор события |
  | `tag` | wire-тег события |
  | `payload` | нагрузка; `NULL` у события без неё |
  | `by_id` | автор события; FK нет — таблица пользователей принадлежит потребителю |
  | `at` | момент события с точностью до секунды |
  | `xid` | транзакция записи, `pg_current_xact_id()` |
  | `number` | номер из identity |

  Первичный ключ `(aggregate_type, aggregate_id, aggregate_version)` — адрес потока и версия:
  единственная проверка ожидаемой версии, таблицы потоков нет. Глобальная позиция — пара
  `(xid, number)`, под чтение по ней — индексы `(xid, number)` и
  `(aggregate_type, xid, number)`. Сортировать по одному `number` нельзя: номер выдаётся до
  commit.

  `es_snapshots` — снапшоты event-sourced агрегатов (`snapshot:` у `Core.Es.Aggregate.Repo.Pg`),
  строка на поток:

  | Колонка | Значение |
  |---|---|
  | `aggregate_type` | тип агрегата — `type:` кодека событий |
  | `aggregate_id` | идентификатор агрегата |
  | `aggregate_version` | версия агрегата, на которой снято состояние |
  | `marker` | маркер кода свёртки: md5 модулей агрегата, кодека и событий плюс `version:` |
  | `state` | состояние агрегата, `:erlang.term_to_binary/1` |
  | `updated_at` | момент последней записи строки |

  Первичный ключ — `(aggregate_type, aggregate_id)`. Таблица создаётся всегда, включены снапшоты
  или нет; снапшот — кэш, строки можно удалить в любой момент.

  `es_checkpoints` — чекпоинты проекций (`Core.Es.Projection`), строка на имя проекции:

  | Колонка | Значение |
  |---|---|
  | `name` | имя проекции — `name:` у `use Core.Es.Projection` |
  | `xid` | глобальная позиция последнего обработанного события: транзакция; `NULL` — начало истории |
  | `number` | глобальная позиция последнего обработанного события: номер; `NULL` вместе с `xid` |
  | `version` | версия проекции (`version:`), которой записана строка |
  | `target_xid` | цель пересборки: транзакция; `NULL` — цели нет |
  | `target_number` | цель пересборки: номер; `NULL` вместе с `target_xid` |

  Первичный ключ — `name`. Таблица создаётся всегда, есть проекции или нет.

  Колонки, ключ и состав индексов — контракт; имена индексов и ограничений — нет.
  """

  use Ecto.Migration

  @doc "Создать таблицы событий и снапшотов и их индексы."
  @spec up() :: :ok

  def up do
    create table(:es_events, primary_key: false) do
      add :aggregate_type, :string, primary_key: true
      add :aggregate_id, :binary_id, primary_key: true
      add :aggregate_version, :integer, primary_key: true
      add :event_id, :binary_id, null: false
      add :tag, :string, null: false
      add :payload, :jsonb
      add :by_id, :binary_id, null: false
      add :at, :utc_datetime, null: false
      add :xid, :xid8, null: false, default: fragment("pg_current_xact_id()")
      add :number, :bigint, null: false, generated: "ALWAYS AS IDENTITY"
    end

    create index(:es_events, [:xid, :number])
    create index(:es_events, [:aggregate_type, :xid, :number])

    create table(:es_snapshots, primary_key: false) do
      add :aggregate_type, :string, primary_key: true
      add :aggregate_id, :binary_id, primary_key: true
      add :aggregate_version, :integer, null: false
      add :marker, :string, null: false
      add :state, :binary, null: false
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create table(:es_checkpoints, primary_key: false) do
      add :name, :string, primary_key: true
      add :xid, :xid8
      add :number, :bigint
      add :version, :integer, null: false
      add :target_xid, :xid8
      add :target_number, :bigint
    end

    create constraint(:es_checkpoints, :es_checkpoints_position,
             check: "(xid IS NULL) = (number IS NULL)"
           )

    create constraint(:es_checkpoints, :es_checkpoints_target,
             check: "(target_xid IS NULL) = (target_number IS NULL)"
           )

    :ok
  end

  @doc "Удалить таблицы событий, снапшотов и чекпоинтов; индексы уходят вместе с ними."
  @spec down() :: :ok

  def down do
    drop_if_exists table(:es_checkpoints)
    drop table(:es_snapshots)
    drop table(:es_events)

    :ok
  end

  @doc """
  Удалить строку `es_checkpoints` проекции `name` — в миграции потребителя, которая удаляет таблицы
  убранной из кода проекции.

      defmodule MyApp.Repo.Migrations.DropAccountList do
        use Ecto.Migration

        def up do
          drop table(:account_list)
          Core.Es.Migration.delete_checkpoint("account_list")
        end

        def down, do: raise(Ecto.MigrationError, "удаление проекции account_list необратимо")
      end

  Библиотека строки сама не удаляет. Обратной операции нет: в `change/0` откат миграции —
  `Ecto.MigrationError`.
  """
  @spec delete_checkpoint(String.t()) :: :ok

  def delete_checkpoint(name) when is_binary(name) and name != "" do
    execute(fn -> repo().query!("DELETE FROM es_checkpoints WHERE name = $1", [name]) end)
  end
end
