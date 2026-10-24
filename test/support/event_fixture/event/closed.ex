defmodule Core.EventFixture.Event.Closed do
  @moduledoc "Агрегат закрыт."

  use Core.Es.Event,
    family: Core.EventFixture.Event,
    payload: nil
end
