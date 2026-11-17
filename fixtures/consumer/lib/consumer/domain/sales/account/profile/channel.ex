defmodule Consumer.Domain.Sales.Account.Profile.Channel do
  @moduledoc "Канал связи профиля: семейство вариантов в тегированной форме, телефоны — по дискриминатору."

  defmodule Kind do
    @moduledoc """
    Вид телефона

    | Значение | Описание |
    |---|---|
    | `:mobile` | мобильный |
    | `:landline` | городской |
    """

    use Core.Enum,
      name: "Вид телефона",
      values: ~w(mobile landline)a
  end

  defmodule Email do
    @moduledoc "Канал: почта."

    use Core.Struct, fields: [address: [prim: Consumer.Domain.Sales.Account.Name]]

    use Core.Labels.Fields,
      labels: [address: "Адрес"]
  end

  defmodule Mobile do
    @moduledoc "Канал: мобильный телефон."

    use Core.Struct,
      fields: [
        number: [prim: Consumer.Domain.Sales.Account.Name],
        kind: [enum: Consumer.Domain.Sales.Account.Profile.Channel.Kind, default: :mobile]
      ]

    use Core.Labels.Fields,
      labels: [number: "Номер", kind: :hidden]
  end

  defmodule Landline do
    @moduledoc "Канал: городской телефон."

    use Core.Struct, fields: [number: [prim: Consumer.Domain.Sales.Account.Name]]

    use Core.Labels.Fields,
      labels: [number: "Номер"]
  end

  use Core.Union,
    variants: [
      {Consumer.Domain.Sales.Account.Profile.Channel.Email, "email"},
      {Consumer.Domain.Sales.Account.Profile.Channel.Mobile, {"phone", kind: :mobile}},
      {Consumer.Domain.Sales.Account.Profile.Channel.Landline, {"phone", kind: :landline}}
    ]
end
