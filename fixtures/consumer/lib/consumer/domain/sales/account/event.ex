defmodule Consumer.Domain.Sales.Account.Event do
  @moduledoc "События счёта."

  alias Consumer.Domain.Sales.Account.Event.Closed
  alias Consumer.Domain.Sales.Account.Event.Frozen
  alias Consumer.Domain.Sales.Account.Event.Opened
  alias Consumer.Domain.Sales.Account.Event.Renamed

  @type t :: Opened.t() | Renamed.t() | Frozen.t() | Closed.t()
end
