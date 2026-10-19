defmodule Core.ReleaseTest.CreateReleaseFixture do
  use Ecto.Migration

  def change do
    create table(:release_fixture) do
      add :name, :text
    end
  end
end
