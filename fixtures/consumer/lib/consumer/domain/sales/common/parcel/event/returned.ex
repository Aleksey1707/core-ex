defmodule Consumer.Domain.Sales.Common.Parcel.Event.Returned do
  alias Consumer.Domain.Sales.Common.Parcel
  alias Consumer.Domain.Sales.Common.UserID

  use Core.Es.Event,
    aggregate_id: Parcel.ID,
    by: UserID,
    payload: nil
end
