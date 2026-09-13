defmodule EventstoreSpike.Repo.Migrations.CreateSpikeRows do
  use Ecto.Migration

  def change do
    create table(:spike_rows) do
      add :label, :text, null: false
    end
  end
end
