defmodule Blind.BadProjectionMissing do
  alias Blind.Account

  # G1 — нет clause project/1 для Account.Event.Closed
  # expect: incompatible types given to project/1
  use Core.Es.Projection,
    name: "blind_bad_missing",
    events: [Account.Event.Opened, Account.Event.Closed]

  @impl true
  def project(%Account.Event.Opened{payload: payload}), do: store(payload.name)

  @impl true
  def clear, do: :ok

  defp store(%Account.Name{}), do: :ok
end

defmodule Blind.BadProjectionTypo do
  alias Blind.Account

  # G3a — опечатка в поле нагрузки без паттерна %Payload{}
  # expect: incompatible types given to project/1
  use Core.Es.Projection,
    name: "blind_bad_typo",
    events: [Account.Event.Opened, Account.Event.Closed]

  @impl true
  def project(%Account.Event.Opened{payload: payload}), do: store(payload.nmae)
  def project(%Account.Event.Closed{}), do: :ok

  @impl true
  def clear, do: :ok

  defp store(_name), do: :ok
end
