defmodule Consumer.S.Prim do
  @moduledoc "Результат bang-конструкторов Prim и `Core.Version.new/0`."

  alias Consumer.Account
  alias Core.Es
  alias Core.Version

  # опечатка в поле результата `now!/0`
  # expect: unknown key .valeu
  def now_bang_typo, do: Es.Event.At.now!().valeu

  # опечатка в поле результата `Version.new/0`
  # expect: unknown key .valeu
  def version_new_typo, do: Version.new().valeu

  # опечатка в поле результата `new!/1`
  # expect: unknown key .valeu
  def new_bang_typo(raw), do: Account.Name.new!(raw).valeu
end
