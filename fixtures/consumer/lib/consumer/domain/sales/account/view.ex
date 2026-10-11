defmodule Consumer.Domain.Sales.Account.View do
  @moduledoc "Представление счёта: jsonb профиля и каналов пере-дампится по выведенной спеке типа и семейства."

  alias Consumer.Domain.Sales.Account

  use Core.View,
    fields: [
      id: [prim: Account.ID],
      profile: [jsonb: Account.Profile, optional: true],
      channels: [list: [jsonb: Account.Profile.Channel]]
    ]
end
