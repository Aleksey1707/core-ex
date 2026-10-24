defmodule Core.Es.Personal.Event do
  @moduledoc """
  События зарезервированного типа агрегата `"core.subject"` — поток субъекта в `es_events`
  (ADR-0079). Владелец потока — `Core.Es.Personal`, кодек — `Core.Es.Personal.Event.Codec`.
  """

  alias Core.Es.Personal.ActorID
  alias Core.Es.Personal.Event.KeyDestroyed
  alias Core.Es.Personal.SubjectID

  use Core.Es.Event.Family,
    aggregate: Core.Es.Personal,
    aggregate_id: SubjectID,
    by: ActorID,
    codec: Core.Es.Personal.Event.Codec

  @type t :: KeyDestroyed.t()
end
