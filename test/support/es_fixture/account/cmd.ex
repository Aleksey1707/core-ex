defmodule Core.EsFixture.Account.Cmd do
  @moduledoc "Команды счёта."

  alias Core.EsFixture.Account.Cmd.Check
  alias Core.EsFixture.Account.Cmd.Close
  alias Core.EsFixture.Account.Cmd.Freeze
  alias Core.EsFixture.Account.Cmd.Open
  alias Core.EsFixture.Account.Cmd.Rename
  alias Core.EsFixture.Account.Cmd.SetHolder

  @type t :: Open.t() | Rename.t() | SetHolder.t() | Freeze.t() | Close.t() | Check.t()
end
