defmodule Consumer.Domain.Sales.Common.Account.Event do
  @moduledoc "События счёта."

  alias Consumer.Domain.Sales.Common.Account.Event.Closed
  alias Consumer.Domain.Sales.Common.Account.Event.Frozen
  alias Consumer.Domain.Sales.Common.Account.Event.Opened
  alias Consumer.Domain.Sales.Common.Account.Event.Renamed

  @type t :: Opened.t() | Renamed.t() | Frozen.t() | Closed.t()
end
