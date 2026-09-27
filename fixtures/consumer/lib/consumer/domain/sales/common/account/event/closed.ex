defmodule Consumer.Domain.Sales.Common.Account.Event.Closed do
  alias Consumer.Domain.Sales.Common.Account
  alias Consumer.Domain.Sales.Common.UserID

  use Core.Es.Event,
    aggregate_id: Account.ID,
    by: UserID,
    payload: nil
end
