defmodule Core.EsFixture.Catalog.Event do
  @moduledoc """
  События каталога: заведение по пути (`Created`), закрытие (`Closed`) и контакт лица с ПДн под
  ключом поля нагрузки (`ContactSet`).
  """

  alias Core.EsFixture.Catalog.Event.Closed
  alias Core.EsFixture.Catalog.Event.ContactSet
  alias Core.EsFixture.Catalog.Event.Created
  alias Core.EventFixture.ActorID
  alias Core.EventFixture.AggID

  use Core.Es.Event.Family,
    aggregate: Core.EsFixture.Catalog,
    aggregate_id: AggID,
    by: ActorID,
    codec: Core.EsFixture.Catalog.Event.Codec

  @type t :: Created.t() | Closed.t() | ContactSet.t()
end
