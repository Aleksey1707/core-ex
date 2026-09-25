defmodule Consumer.Parcel.Event.Returned do
  alias Consumer.Parcel
  alias Consumer.UserID

  use Core.Es.Event,
    aggregate_id: Parcel.ID,
    by: UserID,
    payload: nil
end
