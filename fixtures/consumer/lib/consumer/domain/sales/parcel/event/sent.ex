defmodule Consumer.Domain.Sales.Parcel.Event.Sent do
  alias Consumer.Domain.Sales.Parcel

  defmodule Payload do
    @enforce_keys ~w(note)a
    defstruct @enforce_keys

    def new(note), do: %__MODULE__{note: note}
  end

  use Core.Es.Event,
    family: Parcel.Event,
    payload: Payload
end
