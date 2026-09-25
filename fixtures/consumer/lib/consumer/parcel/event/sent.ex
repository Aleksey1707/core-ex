defmodule Consumer.Parcel.Event.Sent do
  alias Consumer.Parcel
  alias Consumer.UserID

  defmodule Payload do
    @enforce_keys ~w(note)a
    defstruct @enforce_keys

    def new(note), do: %__MODULE__{note: note}
  end

  use Core.Es.Event,
    aggregate_id: Parcel.ID,
    by: UserID,
    payload: Payload
end
