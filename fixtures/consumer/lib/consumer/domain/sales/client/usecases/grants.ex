defmodule Consumer.Domain.Sales.Client.Usecases.Grants do
  @moduledoc "Типовой вызов `execute/2` агрегата с общим модулем нагрузки: предупреждений быть не должно."

  alias Consumer.Domain.Sales.Common.Grants

  def grant(%Grants{} = state, %Grants.Cmd.Grant{} = command) do
    with {:ok, {events, granted}} <- Grants.execute(state, command) do
      {length(events), MapSet.size(granted.roles)}
    end
  end
end
