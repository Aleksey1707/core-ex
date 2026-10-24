defmodule Consumer.Domain.Sales.Account.Event.Renamed do
  alias Consumer.Domain.Sales.Account

  defmodule Payload do
    use Core.Es.Event.Payload, fields: [name: [prim: Account.Name]]

    use Core.Labels.Fields, labels: [name: "Название"]
  end

  use Core.Es.Event,
    family: Account.Event,
    payload: Payload

  use Core.Labels.Event, title: "Счёт переименован"
end
