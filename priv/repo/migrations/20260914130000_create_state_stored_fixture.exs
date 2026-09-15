defmodule Core.TestRepo.Migrations.CreateStateStoredFixture do
  @moduledoc """
  Таблицы state-stored агрегата тестов — `Core.StateStoredFixture`.

  В отличие от соседних миграций это не DDL библиотеки: таблицы агрегата и его дочерних строк
  приложение-потребитель заводит само.
  """

  use Ecto.Migration

  def change do
    create table(:fixture_entities, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :version, :integer, null: false
    end

    create table(:fixture_entity_children, primary_key: false) do
      add :entity_id, references(:fixture_entities, type: :binary_id, on_delete: :delete_all),
        primary_key: true

      add :code, :string, primary_key: true
      add :name, :string, null: false
    end
  end
end
