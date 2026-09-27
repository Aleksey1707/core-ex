defmodule Consumer.Domain.Sales.Common.Account.Cmd do
  @moduledoc "Команды счёта."

  alias Consumer.Domain.Sales.Common.Account.Cmd.Close
  alias Consumer.Domain.Sales.Common.Account.Cmd.Freeze
  alias Consumer.Domain.Sales.Common.Account.Cmd.Open
  alias Consumer.Domain.Sales.Common.Account.Cmd.Rename

  @type t :: Open.t() | Rename.t() | Freeze.t() | Close.t()
end
