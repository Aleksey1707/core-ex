defmodule Consumer.Domain.Sales.Grants.Client.Usecases do
  @moduledoc "Типовой вызов `execute/2` агрегата с общим модулем нагрузки: предупреждений быть не должно."

  alias Consumer.Domain.Sales.Grants

  def grant(%Grants{} = state, %Grants.Cmd.Grant{} = command) do
    with {:ok, {events, granted}} <- Grants.execute(state, command) do
      {length(events), MapSet.size(granted.roles)}
    end
  end

  def assign(%Grants{} = state, %Grants.Cmd.Assign{} = command) do
    with {:ok, {events, assigned}} <- Grants.execute(state, command) do
      {length(events), MapSet.to_list(assigned.roles), Map.keys(assigned.quotas)}
    end
  end

  def assigned_totals(%Grants.Event.Assigned{payload: payload}),
    do: {MapSet.size(payload.roles), Enum.sum(Map.values(payload.quotas))}
end
