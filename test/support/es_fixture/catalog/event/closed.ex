defmodule Core.EsFixture.Catalog.Event.Closed do
  @moduledoc "Каталог закрыт."

  use Core.Es.Event,
    family: Core.EsFixture.Catalog.Event,
    payload: nil
end
