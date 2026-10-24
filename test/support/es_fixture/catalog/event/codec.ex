defmodule Core.EsFixture.Catalog.Event.Codec do
  @moduledoc "Кодек событий каталога."

  alias Core.EsFixture.Catalog.Event

  @tag_by_mod %{
    Event.Created => "catalog.created",
    Event.Closed => "catalog.closed",
    Event.ContactSet => "catalog.contact_set"
  }

  use Core.Es.Event.Codec,
    event: Event,
    type: "catalog",
    tags: @tag_by_mod
end
