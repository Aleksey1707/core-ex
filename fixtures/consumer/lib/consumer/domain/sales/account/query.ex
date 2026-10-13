defmodule Consumer.Domain.Sales.Account.Query do
  @moduledoc "Чтение без проверки доступа: имена по id для ссылок в сведениях событий."

  alias Core.Context

  def get_names(ids, %Context{}) when is_list(ids), do: {:ok, Map.new(ids, &{&1, nil})}
end
