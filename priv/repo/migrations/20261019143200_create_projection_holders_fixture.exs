defmodule Core.TestRepo.Migrations.CreateProjectionHoldersFixture do
  @moduledoc """
  Таблицы владельцев счёта — ПДн read-модели рядом с идентификатором субъекта: проекции тестов
  `Core.EsFixture.Projection` и её сломанной пары `Core.EsFixture.PersonalBrokenProjection`.

  Не DDL библиотеки: таблицы read-модели приложение-потребитель заводит само.
  """

  use Ecto.Migration

  def change do
    create table(:fixture_projection_holders, primary_key: false) do
      add :aggregate_id, :binary_id, primary_key: true
      add :holder, :string
    end

    create table(:fixture_broken_projection_holders, primary_key: false) do
      add :aggregate_id, :binary_id, primary_key: true
      add :holder, :string
    end
  end
end
