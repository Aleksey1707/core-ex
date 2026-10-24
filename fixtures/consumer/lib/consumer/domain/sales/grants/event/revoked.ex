defmodule Consumer.Domain.Sales.Grants.Event.Revoked do
  alias Consumer.Domain.Sales.Grants

  use Core.Es.Event,
    family: Grants.Event,
    payload: Grants.RoleID
end
