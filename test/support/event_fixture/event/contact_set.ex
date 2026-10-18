defmodule Core.EventFixture.Event.ContactSet do
  @moduledoc """
  Контакт указан: два субъекта в одном событии — `contact` под ключом лица `person_id`,
  `note` — под ключом агрегата.
  """

  alias Core.EventFixture.ActorID
  alias Core.EventFixture.AggID

  defmodule Payload do
    @moduledoc "Нагрузка `ContactSet`."

    use Core.Es.Event.Payload,
      fields: [
        person_id: [prim: Core.EventFixture.PersonID, optional: true],
        contact: [prim: Core.EventFixture.Contact, subject: :person_id, optional: true],
        note: [prim: Core.EventFixture.Note, subject: :aggregate_id]
      ]
  end

  use Core.Es.Event,
    aggregate_id: AggID,
    by: ActorID,
    payload: Payload
end
