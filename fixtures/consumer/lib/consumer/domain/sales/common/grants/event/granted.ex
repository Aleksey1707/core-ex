defmodule Consumer.Domain.Sales.Common.Grants.Event.Granted do
  alias Consumer.Domain.Sales.Common.Grants
  alias Consumer.Domain.Sales.Common.UserID

  use Core.Es.Event,
    aggregate_id: Grants.ID,
    by: UserID,
    payload: Grants.RoleID
end
