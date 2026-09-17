defmodule Consumer.Ping.Event do
  alias Consumer.Ping
  alias Consumer.UserID

  defmodule Pinged do
    use Core.Es.Event,
      aggregate_id: Ping.ID,
      by: UserID,
      payload: nil
  end

  defmodule Ponged do
    use Core.Es.Event,
      aggregate_id: Ping.ID,
      by: UserID,
      payload: nil
  end

  @type t :: Pinged.t() | Ponged.t()
end
