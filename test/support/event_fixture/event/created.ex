defmodule Core.EventFixture.Event.Created do
  @moduledoc "Агрегат создан."

  defmodule Payload do
    @moduledoc "Нагрузка `Created`."

    use Core.Es.Event.Payload,
      fields: [name: [prim: Core.EventFixture.Name]]
  end

  use Core.Es.Event,
    family: Core.EventFixture.Event,
    payload: Payload
end
