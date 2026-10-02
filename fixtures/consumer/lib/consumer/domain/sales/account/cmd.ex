defmodule Consumer.Domain.Sales.Account.Cmd do
  @moduledoc "Команды счёта."

  alias Consumer.Domain.Sales.Account.Cmd.Close
  alias Consumer.Domain.Sales.Account.Cmd.Freeze
  alias Consumer.Domain.Sales.Account.Cmd.Open
  alias Consumer.Domain.Sales.Account.Cmd.Rename

  @type t :: Open.t() | Rename.t() | Freeze.t() | Close.t()
end
