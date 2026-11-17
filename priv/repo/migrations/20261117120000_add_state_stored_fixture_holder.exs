defmodule Core.TestRepo.Migrations.AddStateStoredFixtureHolder do
  @moduledoc """
  ПДн-владелец state-stored агрегата тестов — `Core.StateStoredFixture.Entity`.

  jsonb-колонка: живое значение лежит открытым wire-значением Prim, уничтоженное —
  `{"$pd": null}`.
  """

  use Ecto.Migration

  def change do
    alter table(:fixture_entities) do
      add :holder, :map
    end
  end
end
