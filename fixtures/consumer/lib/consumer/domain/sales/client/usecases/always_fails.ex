defmodule Consumer.Domain.Sales.Client.Usecases.AlwaysFails do
  @moduledoc "Разбор `execute/2` с недостижимой clause успеха: предупреждений быть не должно."

  alias Consumer.Domain.Sales.Common.AlwaysFails
  alias Consumer.Domain.Sales.Common.Order
  alias Core.Error

  def refuse(%AlwaysFails{} = state, %Order.Cmd.Place{} = command) do
    case AlwaysFails.execute(state, command) do
      {:ok, {events, _placed}} -> length(events)
      {:error, %Error{code: code}} -> {:error, code}
    end
  end
end
