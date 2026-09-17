defmodule Consumer.Projection do
  @moduledoc "Проекция на события двух агрегатов."

  alias Consumer.Account
  alias Consumer.Order

  use Core.Es.Projection,
    name: "consumer",
    events: [
      Account.Event.Opened,
      Account.Event.Renamed,
      Account.Event.Closed,
      Order.Event.Placed
    ]

  @impl true
  def project(%Account.Event.Opened{payload: %Account.Event.Opened.Payload{} = payload}),
    do: name(payload.name)

  def project(%Account.Event.Renamed{payload: %Account.Event.Renamed.Payload{} = payload}),
    do: name(payload.name)

  def project(%Account.Event.Closed{}), do: :ok

  def project(%Order.Event.Placed{payload: %Order.Event.Placed.Payload{} = payload}),
    do: amount(payload.amount)

  @impl true
  def clear, do: :ok

  # ---

  defp name(%Account.Name{}), do: :ok

  defp amount(%Order.Amount{}), do: :ok
end
