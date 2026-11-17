defmodule Consumer.Domain.Sales.Account.Profile do
  @moduledoc """
  Профиль счёта: тип плагина фасада, объявленного по полям, с вариантами семейств, множеством и
  словарём в полях.
  """

  alias Consumer.Domain.Sales.Order

  use Core.Struct,
    fields: [
      id: [prim: Consumer.Domain.Sales.Account.ID],
      name: [prim: Consumer.Domain.Sales.Account.Name, wire: "title"],
      note: [prim: Consumer.Domain.Sales.Account.Name, optional: true, default: nil],
      status: [enum: Order.Status, default: :placed],
      contacts: [list: [entity: Consumer.Domain.Sales.Account.Profile.Contact]],
      main: [entity: Consumer.Domain.Sales.Account.Profile.Contact, optional: true, default: nil],
      channel: [union: Consumer.Domain.Sales.Account.Profile.Channel, optional: true, default: nil],
      badges: [list: [union: Consumer.Domain.Sales.Account.Profile.Badge], default: []],
      aliases: [set: [prim: Consumer.Domain.Sales.Account.Name], default: MapSet.new()],
      escalation: [
        map: [
          key: [enum: Order.Status],
          value: [entity: Consumer.Domain.Sales.Account.Profile.Contact]
        ],
        default: %{}
      ]
    ]
end
