defmodule Core.Es.Personal.Event.Codec do
  @moduledoc """
  Кодек событий зарезервированного типа агрегата `"core.subject"` (ADR-0079).

  Библиотека подключает его к каждому фасаду (`Core.Codec.Facade`) сама: кодек потребителя с тем
  же `type:` — `CompileError` проверки уникальности типа агрегата фасада. Репозитория у потока
  субъекта нет, поэтому страница потока (`page_stream/4`) его не отдаёт.
  """

  alias Core.Es
  alias Core.Es.Personal.Event

  @tag_by_mod %{Event.KeyDestroyed => "core.subject.key_destroyed"}

  use Es.Event.Codec,
    event: Event,
    type: "core.subject",
    tags: @tag_by_mod
end
