defmodule Consumer.Domain.Sales.Account.Profile.Channel.Codec do
  alias Consumer.Domain.Sales.Account
  alias Consumer.Domain.Sales.Account.Profile.Channel

  use Core.Codec.Plugin,
    union: Channel,
    variants: [
      {Channel.Email, "email", address: [prim: Account.Name]},
      {Channel.Mobile, {"phone", kind: :mobile}, number: [prim: Account.Name]},
      {Channel.Landline, {"phone", kind: :landline}, number: [prim: Account.Name]}
    ]
end
