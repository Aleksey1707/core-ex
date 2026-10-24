defmodule Consumer.Domain.Sales.Account.Event do
  @moduledoc "События счёта."

  alias Consumer.Domain.Sales.Account
  alias Consumer.Domain.Sales.Account.Event.Closed
  alias Consumer.Domain.Sales.Account.Event.Frozen
  alias Consumer.Domain.Sales.Account.Event.HolderSet
  alias Consumer.Domain.Sales.Account.Event.Opened
  alias Consumer.Domain.Sales.Account.Event.Renamed
  alias Consumer.Domain.Sales.Values.UserID

  use Core.Es.Event.Family,
    aggregate: Account,
    aggregate_id: Account.ID,
    by: UserID,
    codec: Account.Event.Codec

  @type t :: Opened.t() | Renamed.t() | HolderSet.t() | Frozen.t() | Closed.t()
end
