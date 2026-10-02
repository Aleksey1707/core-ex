defmodule Consumer.Domain.Sales.Grants.Event.Revoked do
  alias Consumer.Domain.Sales.Grants
  alias Consumer.Domain.Sales.Values.UserID

  use Core.Es.Event,
    aggregate_id: Grants.ID,
    by: UserID,
    payload: Grants.RoleID
end
