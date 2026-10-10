defmodule Consumer.Domain.Sales.Account.Profile do
  @moduledoc "Профиль счёта: тип плагина фасада, объявленного по полям."

  @enforce_keys ~w(id name status contacts)a
  defstruct id: nil, name: nil, note: nil, status: nil, contacts: [], main: nil
end
