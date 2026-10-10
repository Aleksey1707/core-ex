defmodule Consumer.Domain.Sales.Account.Profile.Codec do
  alias Consumer.Domain.Sales.Account
  alias Consumer.Domain.Sales.Order

  use Core.Codec.Plugin,
    types: [Account.Profile, Account.Profile.Contact],
    fields: [
      {Account.Profile,
       id: [prim: Account.ID],
       name: [prim: Account.Name, wire: "title"],
       note: [prim: Account.Name, optional: true],
       status: [enum: Order.Status, default: "placed"],
       contacts: [list: [entity: Account.Profile.Contact]],
       main: [entity: Account.Profile.Contact, optional: true]},
      {Account.Profile.Contact, name: [prim: Account.Name]}
    ]
end
