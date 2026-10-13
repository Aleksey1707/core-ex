defmodule Consumer.Domain.Sales.Values.UserID do
  use Core.Prim.UUID,
    name: "Пользователь",
    version: 7

  use Core.Labels.ID,
    kind: :user,
    resolver: Consumer.Domain.Sales.Account.Query
end
