defmodule Consumer.Domain.Sales.Account.Event.Frozen do
  alias Consumer.Domain.Sales.Account

  use Core.Es.Event,
    family: Account.Event,
    payload: nil
end
