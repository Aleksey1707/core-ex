defmodule Core.Es.Personal.ActorID do
  @moduledoc """
  Актор уничтожения ключа субъекта — `by` события уничтожения ключа
  (`Core.Es.Personal.Event.KeyDestroyed`).

  UUID приходит из Prim пользователя потребителя любой версии, поэтому Prim внешний: ни `new/0`,
  ни проверки версии.
  """

  use Core.Prim.UUID,
    name: "Актор уничтожения ключа субъекта",
    version: :external
end
