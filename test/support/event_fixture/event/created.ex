defmodule Core.EventFixture.Event.Created do
  @moduledoc "Агрегат создан."

  alias Core.EventFixture.ActorID
  alias Core.EventFixture.AggID

  defmodule Payload do
    @moduledoc "Нагрузка `Created`."

    use Core.Es.Event.Payload,
      fields: [name: [prim: Core.EventFixture.Name]]
  end

  use Core.Es.Event,
    aggregate_id: AggID,
    by: ActorID,
    payload: Payload
end
