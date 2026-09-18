defmodule Core.Es.KeyReservation.Schema do
  @moduledoc "Ecto-схема `es_key_reservations` (`Core.Es.KeyReservation.Migration`): резерв ключа."

  use Ecto.Schema

  @primary_key false

  schema "es_key_reservations" do
    field :scope, :string
    field :key, {:array, :string}
    field :aggregate_id, :binary_id
  end

  @type t :: %__MODULE__{}
end
