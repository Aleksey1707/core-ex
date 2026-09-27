defmodule Core.EsFixture.Account.Cmd do
  @moduledoc "Команды счёта."

  alias Core.EsFixture.Account.Cmd.Check
  alias Core.EsFixture.Account.Cmd.Close
  alias Core.EsFixture.Account.Cmd.Freeze
  alias Core.EsFixture.Account.Cmd.Open
  alias Core.EsFixture.Account.Cmd.Rename

  @type t :: Open.t() | Rename.t() | Freeze.t() | Close.t() | Check.t()
end
