defmodule ConsumerTest.WebEvent do
  @moduledoc "Результат `to_wire/2` события страницы событий сужен: опечатка в ключе — предупреждение."

  alias Consumer.Domain.Sales.Account

  # ключа, которого нет в результате
  def wire_typo(%Account.Event.Renamed{} = event, refs),
    # expect: unknown key .aggregate_id in expression
    do: ConsumerWeb.Schemas.Event.to_wire(event, refs).aggregate_id

  # не событие
  # expect: incompatible types given to ConsumerWeb.Schemas.Event.to_wire/2
  def wire_not_event(refs), do: ConsumerWeb.Schemas.Event.to_wire(%{payload: nil}, refs)
end
