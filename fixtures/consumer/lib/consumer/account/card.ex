defmodule Consumer.Account.Card do
  @moduledoc "Карточка счёта для выдачи наружу: тип dump-only плагина фасада."

  @enforce_keys ~w(id name)a
  defstruct @enforce_keys
end

defmodule Consumer.Account.Card.Codec do
  alias Consumer.Account

  use Core.Codec.Plugin,
    types: [Account.Card],
    loadable: false

  @impl true
  def dump(%Account.Card{} = card, codec), do: %{"id" => codec.dump(card.id), "name" => codec.dump(card.name)}
end
