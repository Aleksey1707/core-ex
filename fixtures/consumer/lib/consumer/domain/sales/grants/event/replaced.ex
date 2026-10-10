defmodule Consumer.Domain.Sales.Grants.Event.Replaced do
  alias Consumer.Domain.Sales.Grants
  alias Consumer.Domain.Sales.Values.UserID

  defmodule Payload do
    use Core.Es.ValueChanged,
      type: Grants.RoleID
  end

  use Core.Es.Event,
    aggregate_id: Grants.ID,
    by: UserID,
    payload: Payload
end
