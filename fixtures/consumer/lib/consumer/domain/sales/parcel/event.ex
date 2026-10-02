defmodule Consumer.Domain.Sales.Parcel.Event do
  @moduledoc "События посылки."

  alias Consumer.Domain.Sales.Parcel.Event.Lost
  alias Consumer.Domain.Sales.Parcel.Event.Returned
  alias Consumer.Domain.Sales.Parcel.Event.Sent

  @type t :: Sent.t() | Lost.t() | Returned.t()
end
