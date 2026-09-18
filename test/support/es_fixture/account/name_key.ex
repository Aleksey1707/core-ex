defmodule Core.EsFixture.Account.NameKey do
  @moduledoc """
  Ключ названия счёта: строка названия в области `fixture.name`, общей с ключом пути каталога
  `Core.EsFixture.Catalog.PathKey`.
  """

  alias Core.EsFixture.Account
  alias Core.EsFixture.Account.Event

  use Core.Es.KeyReservation,
    scope: "fixture.name",
    event: Account.Event,
    id: Account.ID,
    code: :name_taken

  @doc "Открытие и переименование занимают название, закрытие снимает."
  @spec reservation(Event.t()) :: {:reserve, Account.Name.t()} | :release | :keep

  @impl true
  def reservation(%Event.Opened{payload: payload}), do: {:reserve, payload.name}
  def reservation(%Event.Renamed{payload: payload}), do: {:reserve, payload.name}
  def reservation(%Event.Frozen{}), do: :keep
  def reservation(%Event.Closed{}), do: :release
  def reservation(%Event.Verified{}), do: :keep

  @doc "Ключ — значение названия."
  @spec to_key(Account.Name.t()) :: String.t()

  @impl true
  def to_key(%Account.Name{} = name), do: Account.Name.value(name)
end
