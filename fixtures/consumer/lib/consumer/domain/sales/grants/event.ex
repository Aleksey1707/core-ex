defmodule Consumer.Domain.Sales.Grants.Event do
  @moduledoc "События выдачи ролей."

  alias Consumer.Domain.Sales.Grants
  alias Consumer.Domain.Sales.Grants.Event.Badged
  alias Consumer.Domain.Sales.Grants.Event.Granted
  alias Consumer.Domain.Sales.Grants.Event.Replaced
  alias Consumer.Domain.Sales.Grants.Event.Revoked
  alias Consumer.Domain.Sales.Values.UserID

  use Core.Es.Event.Family,
    aggregate: Grants,
    aggregate_id: Grants.ID,
    by: UserID,
    codec: Grants.Event.Codec

  @type t :: Granted.t() | Revoked.t() | Replaced.t() | Badged.t()
end
