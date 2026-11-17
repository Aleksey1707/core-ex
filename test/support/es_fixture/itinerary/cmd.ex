defmodule Core.EsFixture.Itinerary.Cmd do
  @moduledoc "Команда маршрута: спланировать шаги."

  defmodule Plan do
    @moduledoc "Спланировать шаги маршрута."

    defstruct steps: []

    @type t :: %__MODULE__{steps: [Core.EsFixture.Itinerary.Step.t()]}
  end

  @type t :: Plan.t()
end
