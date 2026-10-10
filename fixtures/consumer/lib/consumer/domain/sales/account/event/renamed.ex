defmodule Consumer.Domain.Sales.Account.Event.Renamed do
  alias Consumer.Domain.Sales.Account
  alias Consumer.Domain.Sales.Values.UserID

  defmodule Payload do
    use Core.Es.Event.Payload, fields: [name: [prim: Account.Name]]
  end

  use Core.Es.Event,
    aggregate_id: Account.ID,
    by: UserID,
    payload: Payload
end
