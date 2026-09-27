defmodule Consumer.Domain.Sales.Client.Usecases.Ping do
  @moduledoc "Типовой вызов `execute/2` агрегата без нагрузки в событиях: предупреждений быть не должно."

  alias Consumer.Domain.Sales.Common.Ping

  def hit(%Ping{} = state, %Ping.Cmd.Hit{} = command) do
    with {:ok, {_events, hit}} <- Ping.execute(state, command), do: hit.count
  end
end
