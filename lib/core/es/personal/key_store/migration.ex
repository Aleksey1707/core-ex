defmodule Core.Es.Personal.KeyStore.Migration do
  @moduledoc """
  DDL встроенного хранилища ключей (`Core.Es.Personal.KeyStore.Pg`) — для миграции
  приложения-потребителя.

  Потребитель заводит миграцию со своим timestamp и делегирует DDL сюда:

      defmodule MyApp.Infra.DAO.Migrations.CreateEsSubjectKeys do
        use Ecto.Migration

        defdelegate up, to: Core.Es.Personal.KeyStore.Migration
        defdelegate down, to: Core.Es.Personal.KeyStore.Migration
      end

  Таблица живёт в базе `Core.Config.dao()` рядом с `es_events` и восстанавливается вместе с ней
  (ADR-0075). Миграция самой библиотеки (`priv/repo/migrations`) делегирует сюда же.

  `es_subject_keys` — ключ субъекта данных, строка на субъекта:

  | Колонка | Значение |
  |---|---|
  | `id` | идентификатор ключа — непрозрачная ссылка из шифротекста |
  | `subject` | идентификатор субъекта — дамп его UUID-Prim |
  | `wrapped_key` | ключ субъекта под KEK; `NULL` — след уничтоженного ключа |
  | `kek_version` | версия KEK обёртки; `NULL` у следа субъекта, у которого ключа не было |
  | `created_at` | время создания строки |
  | `destroyed_at` | время первого уничтожения; `NULL` у живого ключа |

  Первичный ключ — `id`; полный уникальный индекс по `subject` — у субъекта одна строка на всё
  время жизни, след уничтоженного ключа отвергает новую запись его ПДн.

  Колонки, ключ и состав индексов — контракт; имена индексов — нет.
  """

  use Ecto.Migration

  @doc "Создать таблицу ключей субъектов и её индекс."
  @spec up() :: :ok

  def up do
    create table(:es_subject_keys, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :subject, :text, null: false
      add :wrapped_key, :binary
      add :kek_version, :integer
      add :created_at, :utc_datetime_usec, null: false
      add :destroyed_at, :utc_datetime_usec
    end

    create unique_index(:es_subject_keys, [:subject])

    :ok
  end

  @doc "Удалить таблицу ключей субъектов; индекс уходит вместе с ней."
  @spec down() :: :ok

  def down do
    drop table(:es_subject_keys)

    :ok
  end
end
