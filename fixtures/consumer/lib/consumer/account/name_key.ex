defmodule Consumer.Account.NameKey do
  alias Consumer.Account
  alias Consumer.Account.Event

  use Core.Es.KeyReservation,
    scope: "account.name",
    event: Account.Event,
    id: Account.ID,
    code: :name_taken

  @impl true
  def reservation(%Event.Opened{payload: %Event.Opened.Payload{} = payload}), do: {:reserve, payload.name}
  def reservation(%Event.Renamed{payload: payload}), do: {:reserve, payload.name}
  def reservation(%Event.Frozen{}), do: :keep
  def reservation(%Event.Closed{}), do: :release

  @impl true
  def to_key(%Account.Name{} = name), do: Account.Name.value(name)
end
