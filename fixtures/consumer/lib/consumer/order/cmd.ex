defmodule Consumer.Order.Cmd do
  @moduledoc "Команды заказа."

  alias Consumer.Order.Cmd.Cancel
  alias Consumer.Order.Cmd.Place

  @type t :: Place.t() | Cancel.t()
end
