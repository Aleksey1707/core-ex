defmodule Consumer.Domain.Sales.Parcel.Event.Lost do
  alias Consumer.Domain.Sales.Parcel
  alias Consumer.Domain.Sales.Values.UserID

  defmodule Payload do
    @enforce_keys ~w(note)a
    defstruct @enforce_keys
  end

  use Core.Es.Event,
    aggregate_id: Parcel.ID,
    by: UserID,
    payload: Payload
end
