defmodule Consumer.Domain.Sales.Grants.Event.Badged do
  alias Consumer.Domain.Sales.Account
  alias Consumer.Domain.Sales.Grants

  defmodule Payload do
    use Core.Es.Event.Payload,
      fields: [
        badge: [union: Account.Profile.Badge],
        channel: [union: Account.Profile.Channel, optional: true]
      ]
  end

  use Core.Es.Event,
    family: Grants.Event,
    payload: Payload
end
