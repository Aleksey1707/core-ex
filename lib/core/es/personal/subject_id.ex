defmodule Core.Es.Personal.SubjectID do
  @moduledoc """
  Идентификатор субъекта — `aggregate_id` события уничтожения ключа
  (`Core.Es.Personal.Event.KeyDestroyed`).

  UUID приходит из Prim субъекта потребителя любой версии, поэтому Prim внешний: ни `new/0`, ни
  проверки версии.
  """

  use Core.Prim.UUID,
    name: "Идентификатор субъекта",
    version: :external
end
