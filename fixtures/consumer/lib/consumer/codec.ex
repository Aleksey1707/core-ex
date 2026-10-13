defmodule Consumer.Codec do
  @moduledoc "Кодек: Prim-профиль, фасад и реестр плагинов всех контекстов — граница без проверки исходящих."

  use Boundary,
    check: [out: false],
    exports: [Internal, External]

  defmodule Prim.Internal do
    use Core.Codec,
      uuid: :full,
      datetime: :datetime,
      datetime_tz: "Etc/UTC",
      date: :date,
      decimal: :decimal
  end

  defmodule Prim.External do
    use Core.Codec,
      uuid: :hex,
      datetime: :iso8601,
      datetime_tz: :app,
      date: :iso8601,
      decimal: :string
  end

  @plugins [
    Core.Outbox.Codec,
    Consumer.Domain.Sales.Account.Event.Codec,
    Consumer.Domain.Sales.Account.Codec,
    Consumer.Domain.Sales.Order.Event.Codec,
    Consumer.Domain.Sales.Ping.Event.Codec,
    Consumer.Domain.Sales.Grants.Event.Codec,
    Consumer.Domain.Sales.Account.Card.Codec,
    Consumer.Domain.Sales.Account.Profile.Codec,
    Consumer.Domain.Sales.Account.Profile.Channel.Codec,
    Consumer.Domain.Sales.Account.Profile.Badge.Codec,
    Consumer.Domain.Sales.Account.View.Codec
  ]

  def plugins, do: @plugins
end
