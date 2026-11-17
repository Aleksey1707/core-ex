defmodule Consumer.Domain.Sales.Account.Profile.Badge do
  @moduledoc "Знак профиля: семейство вариантов без обёртки — дискриминатор среди полей."

  defmodule Tier do
    @moduledoc """
    Уровень знака

    | Значение | Описание |
    |---|---|
    | `:gold` | золотой |
    | `:silver` | серебряный |
    """

    use Core.Enum,
      name: "Уровень знака",
      values: ~w(gold silver)a
  end

  defmodule Gold do
    @moduledoc "Знак: золотой."

    use Core.Struct,
      fields: [
        since: [type: :pos_integer],
        tier: [enum: Consumer.Domain.Sales.Account.Profile.Badge.Tier, default: :gold]
      ]

    use Core.Labels.Fields,
      labels: [since: "С даты", tier: :hidden]
  end

  defmodule Silver do
    @moduledoc "Знак: серебряный."

    use Core.Struct, fields: [since: [type: :pos_integer]]

    use Core.Labels.Fields, labels: [since: "С даты"]
  end

  use Core.Union,
    variants: [
      {Consumer.Domain.Sales.Account.Profile.Badge.Gold, [tier: :gold]},
      {Consumer.Domain.Sales.Account.Profile.Badge.Silver, [tier: "silver"]}
    ]
end
