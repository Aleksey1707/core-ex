defmodule Consumer.Domain.Sales.Account.Profile.Contact do
  @moduledoc "Контакт профиля счёта: вложенная сущность плагина по полям."

  @enforce_keys ~w(name)a
  defstruct @enforce_keys
end
