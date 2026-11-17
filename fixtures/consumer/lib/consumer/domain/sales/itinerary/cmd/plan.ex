defmodule Consumer.Domain.Sales.Itinerary.Cmd.Plan do
  @moduledoc "Спланировать шаги маршрута; шаг команды — проекция записи (`Step.write_t()`)."

  alias Consumer.Domain.Sales.Itinerary.Step
  alias Consumer.Domain.Sales.Values.UserID
  alias Core.Es

  use Core.Es.Cmd

  use Core.Struct,
    fields: [
      steps: [list: [entity: Step]],
      at: [prim: Es.Event.At],
      by: [prim: UserID]
    ]
end
