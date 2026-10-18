defmodule Core.Es.Personal.Event do
  @moduledoc """
  События зарезервированного типа агрегата `"core.subject"` — поток субъекта в `es_events`
  (ADR-0079). Кодек — `Core.Es.Personal.Event.Codec`.
  """

  alias Core.Es.Personal.Event.KeyDestroyed

  @type t :: KeyDestroyed.t()
end
