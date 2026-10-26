defmodule Consumer.Domain.Sales.Grants.Cmd.Assign do
  alias Consumer.Domain.Sales.Grants
  alias Consumer.Domain.Sales.Values.UserID
  alias Core.Es

  use Core.Es.Cmd

  use Core.Struct,
    fields: [
      roles: [set: [prim: Grants.RoleID]],
      quotas: [map: [key: [prim: Grants.RoleID], value: [type: :non_neg_integer]], default: %{}],
      at: [prim: Es.Event.At],
      by: [prim: UserID]
    ]
end
