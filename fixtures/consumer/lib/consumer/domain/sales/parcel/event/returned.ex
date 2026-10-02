defmodule Consumer.Domain.Sales.Parcel.Event.Returned do
  alias Consumer.Domain.Sales.Parcel
  alias Consumer.Domain.Sales.Values.UserID

  use Core.Es.Event,
    aggregate_id: Parcel.ID,
    by: UserID,
    payload: nil
end
