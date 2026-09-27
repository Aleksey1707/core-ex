defmodule Consumer.Domain.Sales.Common.Order.Cmd do
  @moduledoc "Команды заказа."

  alias Consumer.Domain.Sales.Common.Order.Cmd.Cancel
  alias Consumer.Domain.Sales.Common.Order.Cmd.Place

  @type t :: Place.t() | Cancel.t()
end
