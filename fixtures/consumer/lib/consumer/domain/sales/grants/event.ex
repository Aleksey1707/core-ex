defmodule Consumer.Domain.Sales.Grants.Event do
  @moduledoc "События выдачи ролей."

  alias Consumer.Domain.Sales.Grants.Event.Granted
  alias Consumer.Domain.Sales.Grants.Event.Revoked

  @type t :: Granted.t() | Revoked.t()
end
