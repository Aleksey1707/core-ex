defmodule Core.EsFixture.Catalog.Event.ContactSet do
  @moduledoc """
  Контакт указан: `contact` — под ключом лица `person_id`, а не каталога. Агрегат с таким
  ПДн-полем снапшотов не держит (`Core.Es.Aggregate.Repo.Pg`, `snapshot:`).
  """

  defmodule Payload do
    @moduledoc "Нагрузка `ContactSet`."

    use Core.Es.Event.Payload,
      fields: [
        person_id: [prim: Core.EventFixture.PersonID, optional: true],
        contact: [prim: Core.EventFixture.Contact, subject: :person_id, optional: true]
      ]
  end

  use Core.Es.Event,
    family: Core.EsFixture.Catalog.Event,
    payload: Payload
end
