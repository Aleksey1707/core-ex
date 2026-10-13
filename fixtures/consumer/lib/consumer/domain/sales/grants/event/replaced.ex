defmodule Consumer.Domain.Sales.Grants.Event.Replaced do
  alias Consumer.Domain.Sales.Grants
  alias Consumer.Domain.Sales.Values.UserID

  defmodule Payload do
    use Core.Es.ValueChanged,
      type: Grants.RoleID

    use Core.Labels.Fields, change: "Роль"
  end

  use Core.Es.Event,
    aggregate_id: Grants.ID,
    by: UserID,
    payload: Payload

  use Core.Labels.Event, title: "Роль заменена"
end
