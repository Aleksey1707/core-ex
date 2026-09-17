defmodule Blind.Codec do
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
    Blind.Account.Event.Codec,
    Blind.Order.Event.Codec,
    Blind.Parcel.Event.Codec
  ]

  def plugins, do: @plugins
end

defmodule Blind.Codec.Internal do
  use Core.Codec.Facade,
    prim: Blind.Codec.Prim.Internal,
    plugins: Blind.Codec.plugins()
end
