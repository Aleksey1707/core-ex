defmodule Consumer.Domain.Sales.Common.Account.Card do
  @moduledoc "Карточка счёта для выдачи наружу: тип dump-only плагина фасада."

  @enforce_keys ~w(id name)a
  defstruct @enforce_keys
end
