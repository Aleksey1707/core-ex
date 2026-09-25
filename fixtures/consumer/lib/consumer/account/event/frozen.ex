defmodule Consumer.Account.Event.Frozen do
  alias Consumer.Account
  alias Consumer.UserID

  use Core.Es.Event,
    aggregate_id: Account.ID,
    by: UserID,
    payload: nil
end
