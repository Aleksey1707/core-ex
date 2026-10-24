defmodule Consumer.Domain.Sales.Grants.Event.Granted do
  alias Consumer.Domain.Sales.Grants

  use Core.Es.Event,
    family: Grants.Event,
    payload: Grants.RoleID
end
