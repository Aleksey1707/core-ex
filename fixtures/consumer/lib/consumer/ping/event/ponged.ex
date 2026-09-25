defmodule Consumer.Ping.Event.Ponged do
  alias Consumer.Ping
  alias Consumer.UserID

  use Core.Es.Event,
    aggregate_id: Ping.ID,
    by: UserID,
    payload: nil
end
