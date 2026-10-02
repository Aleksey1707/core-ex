defmodule Consumer.Domain.Sales.Grants.Cmd do
  @moduledoc "Команды выдачи ролей."

  alias Consumer.Domain.Sales.Grants.Cmd.Grant
  alias Consumer.Domain.Sales.Grants.Cmd.Revoke

  @type t :: Grant.t() | Revoke.t()
end
