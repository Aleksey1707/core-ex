defmodule Consumer.Domain.Sales.Grants.Event.Codec do
  alias Consumer.Domain.Sales.Grants.Event

  @tag_by_mod %{
    Event.Granted => "grants.granted",
    Event.Revoked => "grants.revoked",
    Event.Replaced => "grants.replaced",
    Event.Badged => "grants.badged",
    Event.Assigned => "grants.assigned"
  }

  use Core.Es.Event.Codec,
    family: Event,
    type: "grants",
    tags: @tag_by_mod
end
