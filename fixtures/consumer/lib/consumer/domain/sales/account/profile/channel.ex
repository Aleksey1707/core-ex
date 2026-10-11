defmodule Consumer.Domain.Sales.Account.Profile.Channel do
  @moduledoc "Канал связи профиля: семейство вариантов в тегированной форме, телефоны — по дискриминатору."

  defmodule Email do
    @moduledoc "Канал: почта."

    @enforce_keys ~w(address)a
    defstruct [:address]
  end

  defmodule Mobile do
    @moduledoc "Канал: мобильный телефон."

    @enforce_keys ~w(number)a
    defstruct [:number, kind: :mobile]
  end

  defmodule Landline do
    @moduledoc "Канал: городской телефон."

    @enforce_keys ~w(number)a
    defstruct [:number]
  end
end
