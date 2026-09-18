defmodule Core.Es.KeyReservation.Migration do
  @moduledoc """
  DDL резервов ключей event-sourced агрегатов (`Core.Es.KeyReservation`) — для миграции
  приложения-потребителя.

  Потребитель заводит миграцию со своим timestamp и делегирует DDL сюда:

      defmodule MyApp.Repo.Migrations.CreateEsKeyReservations do
        use Ecto.Migration

        defdelegate up, to: Core.Es.KeyReservation.Migration
        defdelegate down, to: Core.Es.KeyReservation.Migration
      end

  Модуль отдельный от `Core.Es.Migration`: делегирующая миграция выполняется один раз, и таблица,
  дописанная в уже накатанный `up/0`, у потребителя не появилась бы
  (`docs/adr/0018-mutable-key-reservation.md`). Миграция самой библиотеки
  (`priv/repo/migrations`) делегирует сюда же.

  `es_key_reservations` — резерв ключа, строка на занятый ключ:

  | Колонка | Значение |
  |---|---|
  | `scope` | область ключа — `scope:` у `use Core.Es.KeyReservation` |
  | `key` | ключ — части `to_key/1` модуля ключа; строка — список из одной части |
  | `aggregate_id` | идентификатор агрегата, занявшего ключ |

  Первичный ключ `(scope, key)` — ключ занят одним агрегатом; уникальный индекс
  `(scope, aggregate_id)` — у агрегата в области не больше одного ключа.

  Колонки, ключ и состав индексов — контракт; имена индексов — нет.
  """

  use Ecto.Migration

  @doc "Создать таблицу резервов ключей и её индекс."
  @spec up() :: :ok

  def up do
    create table(:es_key_reservations, primary_key: false) do
      add :scope, :text, primary_key: true
      add :key, {:array, :text}, primary_key: true
      add :aggregate_id, :binary_id, null: false
    end

    create unique_index(:es_key_reservations, [:scope, :aggregate_id])

    :ok
  end

  @doc "Удалить таблицу резервов ключей; индекс уходит вместе с ней."
  @spec down() :: :ok

  def down do
    drop table(:es_key_reservations)

    :ok
  end
end
