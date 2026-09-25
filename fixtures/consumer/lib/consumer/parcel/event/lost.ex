defmodule Consumer.Parcel.Event.Lost do
  alias Consumer.Parcel
  alias Consumer.UserID

  defmodule Payload do
    @enforce_keys ~w(note)a
    defstruct @enforce_keys
  end

  use Core.Es.Event,
    aggregate_id: Parcel.ID,
    by: UserID,
    payload: Payload
end
