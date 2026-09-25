defmodule Consumer.Grants.Event do
  @moduledoc "События выдачи ролей."

  alias Consumer.Grants.Event.Granted
  alias Consumer.Grants.Event.Revoked

  @type t :: Granted.t() | Revoked.t()
end
