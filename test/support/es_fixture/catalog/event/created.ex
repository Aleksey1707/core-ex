defmodule Core.EsFixture.Catalog.Event.Created do
  @moduledoc "Каталог заведён по пути."

  defmodule Payload do
    @moduledoc "Нагрузка `Created`."

    use Core.Es.Event.Payload,
      fields: [path: [prim: Core.EventFixture.Name]]
  end

  use Core.Es.Event,
    family: Core.EsFixture.Catalog.Event,
    payload: Payload
end
