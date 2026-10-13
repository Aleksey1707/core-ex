defmodule ConsumerTest.Labels do
  @moduledoc "Подпись значения вне Enum: голова `label/1` закрывает домен."

  alias Consumer.Domain.Sales.Order

  # значение, которого нет в Enum
  # expect: incompatible types given to Consumer.Domain.Sales.Order.Status.label/1
  def unknown_status_label, do: Order.Status.label(:shipped)
end

defmodule ConsumerTest.WebLabels do
  @moduledoc "Результат `to_wire/2` с `labels: true` сужен: опечатка в ключе — предупреждение."

  alias Consumer.Domain.Sales.Account

  # ключа, которого нет в результате
  def wire_typo(%Account.Event.Renamed{} = event, refs),
    # expect: unknown key .titel in expression
    do: ConsumerWeb.Presenters.Event.to_wire(event, refs).titel

  # не событие
  # expect: incompatible types given to ConsumerWeb.Presenters.Event.to_wire/2
  def wire_not_event(refs), do: ConsumerWeb.Presenters.Event.to_wire(%{payload: nil}, refs)
end
