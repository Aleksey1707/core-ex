defmodule Consumer.Domain.Sales.Account.Event.Closed do
  alias Consumer.Domain.Sales.Account

  use Core.Es.Event,
    family: Account.Event,
    payload: nil

  use Core.Labels.Event, title: "Счёт закрыт"
end
