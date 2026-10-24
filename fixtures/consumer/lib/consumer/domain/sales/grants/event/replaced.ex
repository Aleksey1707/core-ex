defmodule Consumer.Domain.Sales.Grants.Event.Replaced do
  alias Consumer.Domain.Sales.Grants

  defmodule Payload do
    use Core.Es.ValueChanged,
      type: Grants.RoleID

    use Core.Labels.Fields, change: "Роль"
  end

  use Core.Es.Event,
    family: Grants.Event,
    payload: Payload

  use Core.Labels.Event, title: "Роль заменена"
end
