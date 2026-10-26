defmodule Consumer.Domain.Sales.Account.Cmd.Rename do
  alias Consumer.Domain.Sales.Account
  alias Consumer.Domain.Sales.Values.UserID
  alias Core.Es

  use Core.Es.Cmd

  use Core.Struct,
    fields: [
      name: [prim: Account.Name],
      at: [prim: Es.Event.At],
      by: [prim: UserID]
    ]
end
