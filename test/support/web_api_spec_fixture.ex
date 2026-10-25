defmodule Core.WebApiSpecFixture do
  @moduledoc """
  Спецификация OpenAPI для тестов `Core.Web.ApiSpecCase`: выборка `POST /orders/search` с фильтром в
  теле и страницей в query (`Core.Web.Params.Schema.page/1`). Обход модулей `:core` находит её как
  спецификацию приложения.
  """

  defmodule Filter do
    @moduledoc false

    @behaviour OpenApiSpex.Schema

    @impl true
    def schema do
      %OpenApiSpex.Schema{
        title: "OrderFilter",
        type: :object,
        properties: %{status: %OpenApiSpex.Schema{type: :string}}
      }
    end
  end

  defmodule ApiSpec do
    @moduledoc false

    @behaviour OpenApiSpex.OpenApi

    alias Core.Web.Params
    alias OpenApiSpex.Info
    alias OpenApiSpex.MediaType
    alias OpenApiSpex.OpenApi
    alias OpenApiSpex.Operation
    alias OpenApiSpex.PathItem
    alias OpenApiSpex.RequestBody

    @impl OpenApi
    def spec do
      %OpenApi{
        info: %Info{title: "Fixture", version: "1"},
        paths: %{
          "/orders/search" => %PathItem{
            post: %Operation{
              operationId: "orders.search",
              parameters: Params.Schema.page(limit_default: 24),
              requestBody: %RequestBody{
                content: %{"application/json" => %MediaType{schema: Core.WebApiSpecFixture.Filter}}
              },
              responses: %{}
            }
          }
        }
      }
    end
  end
end
