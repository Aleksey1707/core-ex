defmodule Consumer.Grants.Event.Granted do
  alias Consumer.Grants
  alias Consumer.UserID

  use Core.Es.Event,
    aggregate_id: Grants.ID,
    by: UserID,
    payload: Grants.RoleID
end
