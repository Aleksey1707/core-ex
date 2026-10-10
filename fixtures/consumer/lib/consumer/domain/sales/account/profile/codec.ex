defmodule Consumer.Domain.Sales.Account.Profile.Codec do
  alias Consumer.Domain.Sales.Account

  use Core.Codec.Plugin,
    types: [Account.Profile],
    fields: [
      {Account.Profile,
       id: [prim: Account.ID],
       name: [prim: Account.Name, wire: "title"],
       note: [prim: Account.Name, optional: true]}
    ]
end
