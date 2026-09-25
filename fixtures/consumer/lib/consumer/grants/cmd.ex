defmodule Consumer.Grants.Cmd do
  @moduledoc "Команды выдачи ролей."

  alias Consumer.Grants.Cmd.Grant
  alias Consumer.Grants.Cmd.Revoke

  @type t :: Grant.t() | Revoke.t()
end
