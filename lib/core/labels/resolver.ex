defmodule Core.Labels.Resolver do
  @moduledoc """
  Резолвер имён словаря ссылок: текущее имя записи по её id (ADR-0063).

  Реализуется в `Query` контекста — владельца записи, а модуль называется в `resolver:` у
  `use Core.Labels.ID` её Prim-идентификатора:

      defmodule MyApp.Domain.Sales.Account.Query do
        @behaviour Core.Labels.Resolver

        @impl true
        def get_names(ids, %Context{} = context), do: ...
      end

  `Core.Labels.Refs.get/2` зовёт `get_names/2` один раз на резолвер пачкой уникальных id страницы
  событий. Ответ — имя по каждому id; у записи без имени — `nil`. Id незаведённой записи — отказ
  `{:error, _}`, и он становится итогом словаря.
  """

  alias Core.Context
  alias Core.Labels.Refs
  alias Core.Result

  @doc "Текущие имена записей по их id."
  @callback get_names(ids :: [struct()], context :: Context.t()) :: Result.t(Refs.t())
end
