defmodule Consumer.Domain.Sales.Account.Profile do
  @moduledoc "Профиль счёта: тип плагина фасада, объявленного по полям."

  @enforce_keys ~w(id name)a
  defstruct id: nil, name: nil, note: nil
end
