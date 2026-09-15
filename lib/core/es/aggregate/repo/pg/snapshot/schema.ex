defmodule Core.Es.Aggregate.Repo.Pg.Snapshot.Schema do
  @moduledoc """
  Ecto-схема `es_snapshots` (`Core.Es.Migration`): снапшот потока event-sourced агрегата.

  `updated_at` ставит база: при вставке — значением по умолчанию, при перезаписи — `now()`.
  """

  use Ecto.Schema

  @primary_key false

  schema "es_snapshots" do
    field :aggregate_type, :string
    field :aggregate_id, :binary_id
    field :aggregate_version, :integer
    field :marker, :string
    field :state, :binary
    field :updated_at, :utc_datetime_usec
  end

  @type t :: %__MODULE__{}
end
