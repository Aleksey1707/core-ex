defmodule Core.TestRepo.Migrations.CreateBrokenProjectionFixture do
  @moduledoc """
  Таблицы read-модели сломанной проекции проверок `Core.Es.ProjectionCase` —
  `Core.EsFixture.BrokenProjection`.

  Не DDL библиотеки: таблицы read-модели приложение-потребитель заводит само.
  """

  use Ecto.Migration

  def change do
    create table(:fixture_broken_projection_streams, primary_key: false) do
      add :aggregate_id, :string, null: false
    end

    create table(:fixture_broken_projection_names, primary_key: false) do
      add :name, :string, null: false
    end
  end
end
