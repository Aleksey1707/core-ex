defmodule Consumer.Domain.Sales.Parcel.Event do
  @moduledoc "События посылки."

  alias Consumer.Domain.Sales.Parcel
  alias Consumer.Domain.Sales.Parcel.Event.Lost
  alias Consumer.Domain.Sales.Parcel.Event.Returned
  alias Consumer.Domain.Sales.Parcel.Event.Sent
  alias Consumer.Domain.Sales.Values.UserID

  use Core.Es.Event.Family,
    aggregate: Parcel,
    aggregate_id: Parcel.ID,
    by: UserID,
    codec: Parcel.Event.Codec

  @type t :: Sent.t() | Lost.t() | Returned.t()
end
