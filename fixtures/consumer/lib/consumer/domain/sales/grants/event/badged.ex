defmodule Consumer.Domain.Sales.Grants.Event.Badged do
  alias Consumer.Domain.Sales.Account
  alias Consumer.Domain.Sales.Grants
  alias Consumer.Domain.Sales.Values.UserID

  defmodule Payload do
    use Core.Es.Event.Payload,
      fields: [
        badge: [union: Account.Profile.Badge],
        channel: [union: Account.Profile.Channel, optional: true]
      ]
  end

  use Core.Es.Event,
    aggregate_id: Grants.ID,
    by: UserID,
    payload: Payload
end
