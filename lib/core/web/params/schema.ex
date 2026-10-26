# `open_api_spex` объявлен в библиотеке `optional: true` (ADR-0064): описание параметров собирается
# только у приложения, у которого он есть. `Core.Web.Params` от него не зависит.
if Code.ensure_loaded?(OpenApiSpex) do
  defmodule Core.Web.Params.Schema do
    @moduledoc """
    OpenAPI-описание параметров запроса, которые разбирает `Core.Web.Params`, для `operation/2`.

    Лист `Schema` занят `OpenApiSpex.Schema`, поэтому вызов — через родителя:

        alias Core.Web.Params

        operation :search,
          parameters: Params.Schema.page(limit_default: 24),
          request_body: {"Фильтр", "application/json", Schemas.Search, required: true},
          responses: [ok: {"Страница", "application/json", Response.Schema.page(Schemas.Found)}]

        def search(conn, params) do
          with {:ok, filter} <- Params.Filter.parse(OpenApiSpex.body_params(conn)),
               {:ok, {limit, offset}} <- Params.page(params, limit_default: 24),
               ...
        end

    Страница — query-параметры `limit` / `offset`: границы — у `Core.Pagination.Limit` /
    `Core.Pagination.Offset`, опции и умолчания — те же, что у `Core.Web.Params.page/2`.

    Модуль собирается, только если `open_api_spex` был у приложения при сборке `core`: добавленный
    позже требует пересборки `core` (`mix deps.compile core --force`).
    """

    alias Core.Pagination
    alias Core.Web.Params

    use Core.Options

    @opts_schema Params.page_opts_schema()
    @doc """
    Query-параметры страницы `limit` / `offset` — то, что разбирает `Core.Web.Params.page/2`.

    ## Опции

    #{Core.Options.docs(@opts_schema)}
    """
    @spec page(keyword()) :: [OpenApiSpex.Parameter.t()]

    def page(opts \\ []) when is_list(opts) do
      [
        parameter(:limit, Pagination.Limit, Keyword.fetch!(opts, :limit_default)),
        parameter(:offset, Pagination.Offset, Keyword.fetch!(opts, :offset_default))
      ]
    end

    # ---

    defp parameter(name, prim, default) do
      bounds = prim.__domain_type_opts__()

      %OpenApiSpex.Parameter{
        name: name,
        in: :query,
        required: false,
        description: prim.name(),
        schema: %OpenApiSpex.Schema{
          type: :integer,
          minimum: Keyword.get(bounds, :min),
          maximum: Keyword.get(bounds, :max),
          default: default
        }
      }
    end
  end
end
