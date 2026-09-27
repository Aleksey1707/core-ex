defmodule Consumer.Domain.Sales.Common.Parcel.Event do
  @moduledoc "События посылки."

  alias Consumer.Domain.Sales.Common.Parcel.Event.Lost
  alias Consumer.Domain.Sales.Common.Parcel.Event.Returned
  alias Consumer.Domain.Sales.Common.Parcel.Event.Sent

  @type t :: Sent.t() | Lost.t() | Returned.t()
end
