defmodule Core.Es.Personal.Event.KeyDestroyed do
  @moduledoc """
  Ключ субъекта уничтожен — событие уничтожения ключа (ADR-0079).

  Пишет его `Core.Es.Personal.destroy_key/3` в поток субъекта версией `1`, нагрузки нет; в outbox
  оно не идёт. Проекция с ПДн объявляет его в `events:` и по нему перестаёт держать данные
  субъекта.
  """

  alias Core.Es.Personal.ActorID
  alias Core.Es.Personal.SubjectID

  use Core.Es.Event,
    aggregate_id: SubjectID,
    by: ActorID,
    payload: nil
end
