defmodule Consumer.Domain.Sales.Grants.Event.Assigned do
  alias Consumer.Domain.Sales.Grants

  defmodule Payload do
    use Core.Es.Event.Payload,
      fields: [
        roles: [set: [prim: Grants.RoleID]],
        quotas: [map: [key: [prim: Grants.RoleID], value: [type: :non_neg_integer]]]
      ]
  end

  use Core.Es.Event,
    family: Grants.Event,
    payload: Payload
end
