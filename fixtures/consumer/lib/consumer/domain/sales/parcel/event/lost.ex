defmodule Consumer.Domain.Sales.Parcel.Event.Lost do
  alias Consumer.Domain.Sales.Parcel

  defmodule Payload do
    @enforce_keys ~w(note)a
    defstruct @enforce_keys
  end

  use Core.Es.Event,
    family: Parcel.Event,
    payload: Payload
end
