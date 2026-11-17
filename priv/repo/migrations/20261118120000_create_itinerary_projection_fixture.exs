defmodule Core.TestRepo.Migrations.CreateItineraryProjectionFixture do
  @moduledoc """
  Таблица шагов маршрута — read-модель проекции `Core.EsFixture.Itinerary.Projection`: открытые
  поля рядом с ПДн-местами.

  Не DDL библиотеки: таблицы read-модели приложение-потребитель заводит само.
  """

  use Ecto.Migration

  def change do
    create table(:fixture_itinerary_steps, primary_key: false) do
      add :aggregate_id, :binary_id, primary_key: true
      add :step_index, :integer, primary_key: true
      add :channel, :string
      add :recipient, :string
      add :content, :string
    end
  end
end
