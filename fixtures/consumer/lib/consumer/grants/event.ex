defmodule Consumer.Grants.Event do
  alias Consumer.Grants
  alias Consumer.UserID

  defmodule Granted do
    use Core.Es.Event,
      aggregate_id: Grants.ID,
      by: UserID,
      payload: Grants.RoleID
  end

  defmodule Revoked do
    use Core.Es.Event,
      aggregate_id: Grants.ID,
      by: UserID,
      payload: Grants.RoleID
  end

  @type t :: Granted.t() | Revoked.t()
end
