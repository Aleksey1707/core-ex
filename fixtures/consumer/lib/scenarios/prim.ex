defmodule Consumer.S.Prim do
  @moduledoc "Результат bang-конструкторов Prim, `from_<key>` идентификатора из ключа и `Core.Version.new/0`."

  alias Consumer.Account
  alias Consumer.DeliveryID
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

  # опечатка в поле результата `from_<key>` идентификатора из ключа
  # expect: unknown key .valeu
  def from_key_typo(number), do: DeliveryID.from_number(number).valeu
end

defmodule Consumer.S.Prim.KeyID do
  @moduledoc "Аргумент приватного `from_key/1` идентификатора из ключа."

  use Core.Prim.UUID,
    name: "Идентификатор из ключа",
    version: 5,
    namespace: Consumer.StreamID.namespace(),
    scope: "scenario"

  # ключ не строка
  # expect: incompatible types given to from_key/1
  def from_number(number) when is_integer(number), do: from_key(number)

  # пустой составной ключ
  # expect: incompatible types given to from_key/1
  def from_nothing, do: from_key([])
end
