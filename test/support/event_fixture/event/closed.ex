defmodule Core.EventFixture.Event.Closed do
  @moduledoc "Агрегат закрыт."

  alias Core.EventFixture.ActorID
  alias Core.EventFixture.AggID

  use Core.Es.Event,
    aggregate_id: AggID,
    by: ActorID,
    payload: nil
end
