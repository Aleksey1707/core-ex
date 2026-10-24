defmodule Consumer.Domain.Sales.Ping.Event.Pinged do
  alias Consumer.Domain.Sales.Ping

  use Core.Es.Event,
    family: Ping.Event,
    payload: nil
end
