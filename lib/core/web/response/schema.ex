# `open_api_spex` объявлен в библиотеке `optional: true` (ADR-0064): схемы обёртки собираются только
# у приложения, у которого он есть. Без него модуля нет — вызов при сборке спеки даст
# UndefinedFunctionError, `Core.Web.Response` от схем не зависит.
if Code.ensure_loaded?(OpenApiSpex) do
  defmodule Core.Web.Response.Schema do
    @moduledoc """
    OpenAPI-схемы обёртки ответа `Core.Web.Response` для `operation/2` (ADR-0065).

    Лист `Schema` занят `OpenApiSpex.Schema`, поэтому вызов — через родителя:

        alias Core.Web.Response

        responses: [
          ok: {"Заказ", "application/json", Response.Schema.success(Order)},
          bad_request: {"Ошибка", "application/json", Response.Schema.error()}
        ]

    Схема данных эндпоинта — аргумент: модуль схемы, `%OpenApiSpex.Schema{}` или
    `%OpenApiSpex.Reference{}`. Схемы успеха и страницы анонимные: названия у них нет, и в components
    они не попадают. `error/0` — одна схема на все статусы ошибки: и на доменную, и на не дошедшую
    до контроллера. Объекты открытые: новое поле обёртки не ломает валидацию ответа у клиента.

    Модуль собирается, только если `open_api_spex` был у приложения при сборке `core`: добавленный
    позже требует пересборки `core` (`mix deps.compile core --force`).
    """

    @doc "Схема успешного ответа без данных — тело `Core.Web.Response.success/0`: `data` — объект без объявленных свойств."
    @spec success() :: OpenApiSpex.Schema.t()

    def success, do: success(%OpenApiSpex.Schema{type: :object})

    @doc "Схема успешного ответа — тело `Core.Web.Response.success/1` с данными по схеме `data`."
    @spec success(module() | OpenApiSpex.Schema.t() | OpenApiSpex.Reference.t()) :: OpenApiSpex.Schema.t()

    def success(data)
        when is_atom(data) or is_struct(data, OpenApiSpex.Schema) or is_struct(data, OpenApiSpex.Reference) do
      %OpenApiSpex.Schema{
        type: :object,
        properties: %{
          status: %OpenApiSpex.Schema{type: :string, enum: ["ok"]},
          data: data
        },
        required: ~w(status data)a
      }
    end

    @doc """
    Схема страницы — тело `Core.Web.Response.success/1` с данными `Core.Web.Response.page_data/2`:
    `data` — `{items: [item], total}`.
    """
    @spec page(module() | OpenApiSpex.Schema.t() | OpenApiSpex.Reference.t()) :: OpenApiSpex.Schema.t()

    def page(item)
        when is_atom(item) or is_struct(item, OpenApiSpex.Schema) or is_struct(item, OpenApiSpex.Reference) do
      success(%OpenApiSpex.Schema{
        type: :object,
        properties: %{
          items: %OpenApiSpex.Schema{type: :array, items: item},
          total: %OpenApiSpex.Schema{type: :integer, minimum: 0, description: "Всего записей по фильтру"}
        },
        required: ~w(items total)a
      })
    end

    @doc "Схема ответа с ошибкой — модуль `ErrorResponse`, общий для всех статусов ошибки."
    @spec error() :: module()

    def error, do: __MODULE__.Error
  end
end
