defmodule Consumer.Domain.Sales.Account.Event.HolderSet do
  alias Consumer.Domain.Sales.Account
  alias Consumer.Domain.Sales.Values.UserID

  defmodule Payload do
    use Core.Es.Event.Payload, fields: [holder: [prim: Account.Holder, subject: :aggregate_id]]

    use Core.Labels.Fields, labels: [holder: "Владелец"]
  end

  use Core.Es.Event,
    aggregate_id: Account.ID,
    by: UserID,
    payload: Payload

  use Core.Labels.Event, title: "Владелец счёта указан"
end
