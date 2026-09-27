defmodule Consumer.Codec do
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
    Consumer.Domain.Sales.Common.Account.Event.Codec,
    Consumer.Domain.Sales.Common.Order.Event.Codec,
    Consumer.Domain.Sales.Common.Ping.Event.Codec,
    Consumer.Domain.Sales.Common.Grants.Event.Codec,
    Consumer.Domain.Sales.Common.Account.Card.Codec
  ]

  def plugins, do: @plugins
end
