defmodule Consumer.Domain.Sales.Common.Account.Card.Codec do
  alias Consumer.Domain.Sales.Common.Account

  use Core.Codec.Plugin,
    types: [Account.Card],
    loadable: false

  @impl true
  def dump(%Account.Card{} = card, codec), do: %{"id" => codec.dump(card.id), "name" => codec.dump(card.name)}
end
