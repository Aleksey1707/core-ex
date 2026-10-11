defmodule Consumer.Domain.Sales.Account.Profile.Badge.Codec do
  alias Consumer.Domain.Sales.Account.Profile.Badge

  use Core.Codec.Plugin,
    union: Badge,
    variants: [
      {Badge.Gold, [tier: :gold], since: [type: :pos_integer]},
      {Badge.Silver, [tier: "silver"], since: [type: :pos_integer]}
    ]
end
