defmodule Consumer.Domain.Sales.Account.Profile.Contact do
  @moduledoc "Контакт профиля счёта: вложенная сущность плагина по полям."

  use Core.Struct, fields: [name: [prim: Consumer.Domain.Sales.Account.Name]]
end
