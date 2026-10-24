defmodule Core.EsFixture.Account.HolderKey do
  @moduledoc """
  Ключ владельца счёта — ключ из ПДн: в области `fixture.holder` лежит индекс владельца, а не
  его значение.
  """

  alias Core.EsFixture.Account
  alias Core.EsFixture.Account.Event

  use Core.Es.KeyReservation,
    scope: "fixture.holder",
    aggregate: Account,
    code: :holder_taken,
    personal: true

  @doc "Указание владельца занимает ключ, закрытие снимает."
  @spec reservation(Event.t()) :: {:reserve, Account.Holder.t()} | :release | :keep

  @impl true
  def reservation(%Event.Opened{}), do: :keep
  def reservation(%Event.Renamed{}), do: :keep
  def reservation(%Event.HolderSet{payload: payload}), do: {:reserve, payload.holder}
  def reservation(%Event.Frozen{}), do: :keep
  def reservation(%Event.Closed{}), do: :release
  def reservation(%Event.Verified{}), do: :keep

  @doc "Ключ — значение владельца."
  @spec to_key(Account.Holder.t()) :: String.t()

  @impl true
  def to_key(%Account.Holder{} = holder), do: Account.Holder.value(holder)
end
