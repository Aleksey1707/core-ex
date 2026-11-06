defmodule Consumer.Domain.Sales.Account.AtVersion.View do
  @moduledoc """
  Представление счёта на версии — read-модель по назначению над `Consumer.Domain.Sales.Account`.

  `holder` у уничтоженного ПДн-значения — `%{destroyed: true}`, а не строка: историческое чтение
  не обходит уничтожение ключа субъекта.
  """

  alias Consumer.Domain.Sales.Account
  alias Core.Es.Personal.Destroyed
  alias Core.Prim
  alias Core.Version

  use Core.View,
    fields: [
      id: [prim: Account.ID],
      version: [prim: Version],
      name: [prim: Account.Name],
      status: [type: :string],
      holder: [type: :map, optional: true]
    ]

  @doc "Состояние счёта → представление."
  @spec from_state(Account.t()) :: t()

  def from_state(%Account{} = state) do
    %__MODULE__{
      id: Prim.unwrap(state.id),
      version: Version.value(state.version),
      name: Prim.unwrap(state.name),
      status: Atom.to_string(state.status),
      holder: holder(state.holder)
    }
  end

  # ---

  defp holder(nil), do: nil
  defp holder(%Destroyed{}), do: %{destroyed: true}
  defp holder(%Account.Holder{} = holder), do: %{destroyed: false, value: Prim.unwrap(holder)}
end
