defmodule Consumer.Domain.Sales.Account.Profile.Channel do
  @moduledoc "Канал связи профиля: семейство вариантов в тегированной форме, телефоны — по дискриминатору."

  defmodule Email do
    @moduledoc "Канал: почта."

    @enforce_keys ~w(address)a
    defstruct [:address]

    use Core.Labels.Fields,
      fields: [address: [prim: Consumer.Domain.Sales.Account.Name]],
      labels: [address: "Адрес"]
  end

  defmodule Mobile do
    @moduledoc "Канал: мобильный телефон."

    @enforce_keys ~w(number)a
    defstruct [:number, kind: :mobile]

    use Core.Labels.Fields,
      fields: [number: [prim: Consumer.Domain.Sales.Account.Name]],
      labels: [number: "Номер", kind: :hidden]
  end

  defmodule Landline do
    @moduledoc "Канал: городской телефон."

    @enforce_keys ~w(number)a
    defstruct [:number]

    use Core.Labels.Fields,
      fields: [number: [prim: Consumer.Domain.Sales.Account.Name]],
      labels: [number: "Номер"]
  end
end
