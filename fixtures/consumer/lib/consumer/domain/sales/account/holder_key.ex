defmodule Consumer.Domain.Sales.Account.HolderKey do
  alias Consumer.Domain.Sales.Account
  alias Consumer.Domain.Sales.Account.Event

  use Core.Es.KeyReservation,
    scope: "account.holder",
    event: Account.Event,
    id: Account.ID,
    code: :holder_taken,
    personal: true

  @impl true
  def reservation(%Event.Opened{}), do: :keep
  def reservation(%Event.Renamed{}), do: :keep
  def reservation(%Event.HolderSet{payload: %Event.HolderSet.Payload{} = payload}), do: {:reserve, payload.holder}
  def reservation(%Event.Frozen{}), do: :keep
  def reservation(%Event.Closed{}), do: :release

  @impl true
  def to_key(%Account.Holder{} = holder), do: Account.Holder.value(holder)
end
