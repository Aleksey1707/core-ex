defmodule Consumer.Domain.Sales.Common.Parcel.Event.Sent do
  alias Consumer.Domain.Sales.Common.Parcel
  alias Consumer.Domain.Sales.Common.UserID

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
