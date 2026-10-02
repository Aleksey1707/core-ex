defmodule Consumer.Domain.Sales.Ping.Cmd do
  @moduledoc "Команды пинга."

  alias Consumer.Domain.Sales.Ping.Cmd.Hit

  @type t :: Hit.t()
end
