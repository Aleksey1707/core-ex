defmodule Consumer.Domain.Sales.Order.Cmd do
  @moduledoc "Команды заказа."

  alias Consumer.Domain.Sales.Order.Cmd.Cancel
  alias Consumer.Domain.Sales.Order.Cmd.Place

  @type t :: Place.t() | Cancel.t()
end
