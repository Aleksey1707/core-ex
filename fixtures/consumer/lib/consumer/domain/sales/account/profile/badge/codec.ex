defmodule Consumer.Domain.Sales.Account.Profile.Badge.Codec do
  alias Consumer.Domain.Sales.Account.Profile.Badge

  @tier_by_mod %{Badge.Gold => :gold, Badge.Silver => "silver"}

  use Core.Codec.Plugin,
    union: Badge,
    variants: Enum.map(@tier_by_mod, fn {mod, tier} -> {mod, [tier: tier], since: [type: :pos_integer]} end)
end
