defmodule Consumer.Domain.Sales.Parcel.Event.Returned do
  alias Consumer.Domain.Sales.Parcel

  use Core.Es.Event,
    family: Parcel.Event,
    payload: nil
end
