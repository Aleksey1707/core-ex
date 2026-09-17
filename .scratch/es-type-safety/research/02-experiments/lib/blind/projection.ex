defmodule Blind.Projection do
  alias Blind.Account

  use Core.Es.Projection,
    name: "blind",
    events: [Account.Event.Opened, Account.Event.Renamed, Account.Event.Closed]

  @impl true
  def project(%Account.Event.Opened{payload: payload}), do: store(payload.name)
  def project(%Account.Event.Renamed{payload: payload}), do: store(payload.name)
  def project(%Account.Event.Closed{}), do: :ok

  @impl true
  def clear, do: :ok

  defp store(%Account.Name{}), do: :ok
end
