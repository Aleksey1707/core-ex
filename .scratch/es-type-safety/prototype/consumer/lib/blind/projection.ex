defmodule Blind.Projection do
  @moduledoc "Корректная проекция на события двух агрегатов."

  alias Blind.Account
  alias Blind.Order

  use Core.Es.Projection,
    name: "blind",
    events: [Account.Event.Opened, Account.Event.Renamed, Account.Event.Closed, Order.Event.Placed]

  @impl true
  def project(%Account.Event.Opened{payload: payload}), do: store(payload.name)

  def project(%Account.Event.Renamed{payload: %Account.Event.Renamed.Payload{} = payload}),
    do: store(payload.name)

  def project(%Account.Event.Closed{}), do: :ok
  def project(%Order.Event.Placed{payload: payload}), do: amount(payload.amount)

  @impl true
  def clear, do: :ok

  defp store(%Account.Name{}), do: :ok
  defp amount(%Order.Amount{}), do: :ok
end
