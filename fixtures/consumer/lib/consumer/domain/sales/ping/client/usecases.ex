defmodule Consumer.Domain.Sales.Ping.Client.Usecases do
  @moduledoc "Типовой вызов `execute/2` агрегата без нагрузки в событиях: предупреждений быть не должно."

  alias Consumer.Domain.Sales.Ping

  def hit(%Ping{} = state, %Ping.Cmd.Hit{} = command) do
    with {:ok, {_events, hit}} <- Ping.execute(state, command), do: hit.count
  end
end
