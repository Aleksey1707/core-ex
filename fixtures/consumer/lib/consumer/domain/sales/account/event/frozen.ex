defmodule Consumer.Domain.Sales.Account.Event.Frozen do
  alias Consumer.Domain.Sales.Account
  alias Consumer.Domain.Sales.Values.UserID

  use Core.Es.Event,
    aggregate_id: Account.ID,
    by: UserID,
    payload: nil
end
