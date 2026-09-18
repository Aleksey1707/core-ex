defmodule Core.TestRepo.Migrations.CreateConstraintErrorsFixture do
  @moduledoc """
  Таблицы репозиториев тестов `Core.Repo.ConstraintErrorsCase` — `Core.ConstraintErrorsFixture`.

  Как и таблицы `Core.StateStoredFixture`, это не DDL библиотеки: ограничения здесь — по одному
  на каждый вид сверки case-модуля (unique-индекс, FK, check и FK дочерней таблицы).
  """

  use Ecto.Migration

  def change do
    create table(:fixture_constraint_refs, primary_key: false) do
      add :id, :binary_id, primary_key: true
    end

    create table(:fixture_constrained, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :version, :integer, null: false
      add :ref_id, references(:fixture_constraint_refs, type: :binary_id), null: false
    end

    create unique_index(:fixture_constrained, [:name])
    create constraint(:fixture_constrained, :fixture_constrained_version_positive, check: "version > 0")

    create table(:fixture_constrained_children, primary_key: false) do
      add :entity_id, references(:fixture_constrained, type: :binary_id, on_delete: :delete_all), primary_key: true

      add :code, :string, primary_key: true
      add :ref_id, references(:fixture_constraint_refs, type: :binary_id), null: false
    end
  end
end
