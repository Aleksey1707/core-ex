defmodule Consumer.Account.Cmd do
  @moduledoc "Команды счёта."

  alias Consumer.Account.Cmd.Close
  alias Consumer.Account.Cmd.Freeze
  alias Consumer.Account.Cmd.Open
  alias Consumer.Account.Cmd.Rename

  @type t :: Open.t() | Rename.t() | Freeze.t() | Close.t()
end
