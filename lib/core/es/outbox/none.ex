defmodule Core.Es.Outbox.None do
  @moduledoc """
  Маппер-заглушка агрегата, объявившего `outbox: :none`: события пишутся в хранилище,
  наружу не публикуются.

  Подставляется билдерами (`use Core.Repo.Pg.StateStored`, `use Core.Es.Aggregate.Repo.Pg`)
  вместо `<Aggregate>.Outbox`, поэтому путь записи остаётся один: `Core.Outbox.Repo.append/3`
  получает пустой список и запросов не делает.
  """

  alias Core.Es
  alias Core.Outbox

  @doc "Список событий → записей outbox нет."
  @spec from_events([Es.Event.t()]) :: {:ok, [Outbox.Record.t()]}

  def from_events(events) when is_list(events), do: {:ok, []}
end
