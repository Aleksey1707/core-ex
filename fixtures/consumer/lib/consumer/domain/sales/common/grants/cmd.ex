defmodule Consumer.Domain.Sales.Common.Grants.Cmd do
  @moduledoc "Команды выдачи ролей."

  alias Consumer.Domain.Sales.Common.Grants.Cmd.Grant
  alias Consumer.Domain.Sales.Common.Grants.Cmd.Revoke

  @type t :: Grant.t() | Revoke.t()
end
