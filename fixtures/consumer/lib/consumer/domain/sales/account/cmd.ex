defmodule Consumer.Domain.Sales.Account.Cmd do
  @moduledoc "Команды счёта."

  alias Consumer.Domain.Sales.Account.Cmd.Close
  alias Consumer.Domain.Sales.Account.Cmd.Freeze
  alias Consumer.Domain.Sales.Account.Cmd.Open
  alias Consumer.Domain.Sales.Account.Cmd.Rename
  alias Consumer.Domain.Sales.Account.Cmd.SetHolder

  @type t :: Open.t() | Rename.t() | SetHolder.t() | Freeze.t() | Close.t()
end
