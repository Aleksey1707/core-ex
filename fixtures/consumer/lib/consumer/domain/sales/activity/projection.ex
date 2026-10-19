defmodule Consumer.Domain.Sales.Activity.Projection do
  @moduledoc """
  Read-модель активности: проекция на события двух агрегатов. Владелец счёта — ПДн: строку
  субъекта проекция чистит по событию уничтожения ключа.
  """

  alias Consumer.Domain.Sales.Account
  alias Consumer.Domain.Sales.Order
  alias Core.Es.Personal.Destroyed
  alias Core.Es.Personal.Event.KeyDestroyed

  use Core.Es.Projection,
    name: "activity",
    events: [
      Account.Event.Opened,
      Account.Event.Renamed,
      Account.Event.HolderSet,
      Account.Event.Closed,
      Order.Event.Placed,
      KeyDestroyed
    ]

  @impl true
  def project(%Account.Event.Opened{payload: %Account.Event.Opened.Payload{} = payload}),
    do: name(payload.name)

  def project(%Account.Event.Renamed{payload: %Account.Event.Renamed.Payload{} = payload}),
    do: name(payload.name)

  def project(%Account.Event.HolderSet{payload: %Account.Event.HolderSet.Payload{} = payload}),
    do: holder(payload.holder)

  def project(%Account.Event.Closed{}), do: :ok

  def project(%Order.Event.Placed{payload: %Order.Event.Placed.Payload{} = payload}),
    do: amount(payload.amount)

  def project(%KeyDestroyed{}), do: :ok

  @impl true
  def clear, do: :ok

  # ---

  defp name(%Account.Name{}), do: :ok

  defp holder(%Account.Holder{}), do: :ok
  defp holder(%Destroyed{}), do: :ok

  defp amount(%Order.Amount{}), do: :ok
end
