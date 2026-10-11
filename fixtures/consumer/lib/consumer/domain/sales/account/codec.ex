defmodule Consumer.Domain.Sales.Account.Codec do
  @moduledoc "Ручной плагин нагрузки `Opened`: её wire-форму задаёт плагин типа, а не кодек событий."

  alias Consumer.Domain.Sales.Account
  alias Consumer.Domain.Sales.Account.Event

  use Core.Codec.Plugin,
    types: [Event.Opened.Payload]

  @impl true
  def dump(%Event.Opened.Payload{} = payload, codec), do: %{"name" => codec.dump(payload.name)}

  @impl true
  def load(Event.Opened.Payload, wire, codec) when is_map(wire) do
    with {:ok, name} <- codec.load(Account.Name, field(wire, :name)) do
      {:ok, Event.Opened.Payload.new(name)}
    end
  end
end
