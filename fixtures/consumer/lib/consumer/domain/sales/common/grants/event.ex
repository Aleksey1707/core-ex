defmodule Consumer.Domain.Sales.Common.Grants.Event do
  @moduledoc "События выдачи ролей."

  alias Consumer.Domain.Sales.Common.Grants.Event.Granted
  alias Consumer.Domain.Sales.Common.Grants.Event.Revoked

  @type t :: Granted.t() | Revoked.t()
end
