defmodule Consumer.Domain.Sales.Account.Query do
  @moduledoc "Чтение без проверки доступа: имена по id для ссылок в сведениях событий."

  @behaviour Core.Labels.Resolver

  alias Core.Context

  @impl true
  def get_names(ids, %Context{}) when is_list(ids), do: {:ok, Map.new(ids, &{&1, nil})}
end
