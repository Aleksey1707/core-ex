defmodule Consumer.Domain.Sales.NeverFails.Client.Usecases do
  @moduledoc "Разбор `execute/2` с недостижимой clause ошибки: предупреждений быть не должно."

  alias Consumer.Domain.Sales.NeverFails
  alias Consumer.Domain.Sales.Order
  alias Core.Error

  def cancel(%NeverFails{} = state, %Order.Cmd.Cancel{} = command) do
    case NeverFails.execute(state, command) do
      {:ok, {events, cancelled}} -> {length(events), cancelled.cancelled?}
      {:error, %Error{code: code}} -> {:error, code}
    end
  end
end
