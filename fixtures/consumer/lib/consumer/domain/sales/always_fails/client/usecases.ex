defmodule Consumer.Domain.Sales.AlwaysFails.Client.Usecases do
  @moduledoc "Разбор `execute/2` с недостижимой clause успеха: предупреждений быть не должно."

  alias Consumer.Domain.Sales.AlwaysFails
  alias Consumer.Domain.Sales.Order
  alias Core.Error

  def refuse(%AlwaysFails{} = state, %Order.Cmd.Place{} = command) do
    case AlwaysFails.execute(state, command) do
      {:ok, {events, _placed}} -> length(events)
      {:error, %Error{code: code}} -> {:error, code}
    end
  end
end
