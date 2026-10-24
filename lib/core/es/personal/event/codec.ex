defmodule Core.Es.Personal.Event.Codec do
  @moduledoc """
  Кодек событий зарезервированного типа агрегата `"core.subject"` (ADR-0079).

  В `plugins:` фасада он не входит: событие потока субъекта пишет и читает сам кодек
  (`Core.Es.Store`), фасад приложения ему — только для вложенных Prim. Тип зарезервирован сборкой
  кодека: `use Core.Es.Event.Codec` с `type: "core.subject"` в другом модуле — `CompileError`.
  Репозитория у потока субъекта нет, поэтому страница потока (`page_stream/4`) его не отдаёт.
  """

  alias Core.Es
  alias Core.Es.Personal.Event

  @tag_by_mod %{Event.KeyDestroyed => "core.subject.key_destroyed"}

  use Es.Event.Codec,
    family: Event,
    type: "core.subject",
    tags: @tag_by_mod
end
