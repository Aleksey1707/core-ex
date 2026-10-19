defmodule ConsumerTest.Prim do
  @moduledoc "Результат bang-конструкторов Prim, `from_<key>` идентификатора из ключа и `Core.Version.new/0`."

  alias Consumer.Domain.Sales.Account
  alias Consumer.Domain.Sales.Values.DeliveryID
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

defmodule ConsumerTest.Prim.KeyID do
  @moduledoc "Аргумент приватного `from_key/1` идентификатора из ключа."

  use Core.Prim.UUID,
    name: "Идентификатор из ключа",
    version: 5,
    namespace: Consumer.Infra.StreamID.namespace(),
    scope: "scenario"

  # ключ не строка
  # expect: incompatible types given to from_key/1
  def from_number(number) when is_integer(number), do: from_key(number)

  # пустой составной ключ
  # expect: incompatible types given to from_key/1
  def from_nothing, do: from_key([])
end

defmodule ConsumerTest.Prim.DueAt do
  @moduledoc "Генерируемые `now/0` и `now!/0` datetime-Prim потребителя: время берётся у `Core.Clock`."

  use Core.Prim.DateTime,
    name: "Срок",
    precision: :microsecond

  def due_now, do: now()

  # опечатка в поле результата сгенерированного `now!/0`
  # expect: unknown key .valeu
  def now_bang_typo, do: now!().valeu
end

defmodule ConsumerTest.Prim.DueDay do
  @moduledoc "Генерируемые `today/0` и `today!/0` date-Prim потребителя: дата берётся у `Core.Clock`."

  use Core.Prim.Date, name: "День срока"

  def due_today, do: today()

  # опечатка в поле результата сгенерированного `today!/0`
  # expect: unknown key .valeu
  def today_bang_typo, do: today!().valeu
end
