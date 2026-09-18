defmodule Core.EsFixture.Catalog.PathKey do
  @moduledoc """
  Ключ пути каталога: части пути, разделённые `/`, в области `fixture.name`, общей с ключом
  названия счёта `Core.EsFixture.Account.NameKey`.
  """

  alias Core.EventFixture.AggID
  alias Core.EventFixture.Event
  alias Core.EventFixture.Name

  use Core.Es.KeyReservation,
    scope: "fixture.name",
    event: Event,
    id: AggID,
    code: :name_taken

  @doc "Заведение занимает путь, закрытие снимает."
  @spec reservation(Event.t()) :: {:reserve, Name.t()} | :release

  @impl true
  def reservation(%Event.Created{payload: payload}), do: {:reserve, payload.name}
  def reservation(%Event.Closed{}), do: :release

  @doc "Ключ — части пути."
  @spec to_key(Name.t()) :: [String.t(), ...]

  @impl true
  def to_key(%Name{} = path), do: String.split(Name.value(path), "/")
end
