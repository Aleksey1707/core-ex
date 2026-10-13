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
          bad_request: {"Ошибка", "application/json", Response.Schema.error()}
        ]

    `error/0` — одна схема на все статусы ошибки: и на доменную, и на не дошедшую до контроллера.

    Модуль собирается, только если `open_api_spex` был у приложения при сборке `core`: добавленный
    позже требует пересборки `core` (`mix deps.compile core --force`).
    """

    @doc "Схема ответа с ошибкой — модуль `ErrorResponse`, общий для всех статусов ошибки."
    @spec error() :: module()

    def error, do: __MODULE__.Error
  end
end
