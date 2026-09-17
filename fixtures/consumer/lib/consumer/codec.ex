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
    Consumer.Account.Event.Codec,
    Consumer.Order.Event.Codec,
    Consumer.Ping.Event.Codec,
    Consumer.Grants.Event.Codec,
    Consumer.Account.Card.Codec
  ]

  def plugins, do: @plugins
end

defmodule Consumer.Codec.Internal do
  use Core.Codec.Facade,
    prim: Consumer.Codec.Prim.Internal,
    plugins: Consumer.Codec.plugins()
end
