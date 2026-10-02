defmodule Consumer.Codec do
  @moduledoc "Кодек: Prim-профиль, фасад и реестр плагинов всех контекстов — граница без проверки исходящих."

  use Boundary,
    check: [out: false],
    exports: [Internal]

  defmodule Prim.Internal do
    use Core.Codec,
      uuid: :full,
      datetime: :datetime,
      datetime_tz: "Etc/UTC",
      date: :date,
      decimal: :decimal
  end

  @plugins [
    Core.Outbox.Codec,
    Consumer.Domain.Sales.Account.Event.Codec,
    Consumer.Domain.Sales.Order.Event.Codec,
    Consumer.Domain.Sales.Ping.Event.Codec,
    Consumer.Domain.Sales.Grants.Event.Codec,
    Consumer.Domain.Sales.Account.Card.Codec
  ]

  def plugins, do: @plugins
end
