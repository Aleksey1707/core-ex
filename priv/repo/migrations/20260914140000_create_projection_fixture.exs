defmodule Core.TestRepo.Migrations.CreateProjectionFixture do
  @moduledoc """
  Таблица read-модели проекции тестов — `Core.EsFixture.Projection`.

  Не DDL библиотеки: таблицы read-модели приложение-потребитель заводит само.
  """

  use Ecto.Migration

  def change do
    create table(:fixture_projection_streams, primary_key: false) do
      add :aggregate_type, :string, primary_key: true
      add :aggregate_id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :closed, :boolean, null: false
    end
  end
end
