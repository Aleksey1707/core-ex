defmodule Consumer.Domain.Sales.Account.Profile.Badge do
  @moduledoc "Знак профиля: семейство вариантов без обёртки — дискриминатор среди полей."

  defmodule Gold do
    @moduledoc "Знак: золотой."

    @enforce_keys ~w(since)a
    defstruct [:since, tier: :gold]
  end

  defmodule Silver do
    @moduledoc "Знак: серебряный."

    @enforce_keys ~w(since)a
    defstruct [:since]
  end
end
