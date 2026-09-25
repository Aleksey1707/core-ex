defmodule Consumer.Parcel.Event do
  @moduledoc "События посылки."

  alias Consumer.Parcel.Event.Lost
  alias Consumer.Parcel.Event.Returned
  alias Consumer.Parcel.Event.Sent

  @type t :: Sent.t() | Lost.t() | Returned.t()
end
