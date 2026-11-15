defmodule Core.Repo.Pg.Config do
  @moduledoc """
  Конфигурация write-пути репозитория, которую `use Core.Repo.Pg` кладёт в модуль-потребитель
  атрибутом `@pg`.

  Единственная форма конфигурации для обоих write-builder'ов и для кастомных методов репозитория
  (`Repo.Pg.get_by(@pg, …)`, `Repo.Pg.page_by(@pg, …)`). Все поля обязательны; значения-выражения
  (`query:`, `to_entity:`, `to_model:`, `to_id:`, `default_filters:`) вычисляются при компиляции
  модуля-потребителя, поэтому правка ключа — правка одного `defstruct`, а не двух макросов.

  Головы `Core.Repo.Pg` по-прежнему матчат конфигурацию по ключам; правка ключа в коде
  потребителя идёт через `%{@pg | …}`.
  """

  alias Core.Context

  @type t :: %__MODULE__{
          dao: module() | nil,
          module: module(),
          schema: module(),
          query: Ecto.Queryable.t(),
          default_filters: (Context.t() -> term()),
          to_entity: (term() -> struct()) | nil,
          to_model: (struct() -> map()) | nil,
          to_id: (term() -> term()),
          version_field: atom(),
          shadow_copy?: boolean(),
          errors: module(),
          constraint_errors: %{{atom(), atom()} => atom()}
        }

  @enforce_keys [
    :dao,
    :module,
    :schema,
    :query,
    :default_filters,
    :to_entity,
    :to_model,
    :to_id,
    :version_field,
    :shadow_copy?,
    :errors,
    :constraint_errors
  ]

  defstruct @enforce_keys
end
