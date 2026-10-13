# Условный, как `Core.Web.Response.Schema`: без `open_api_spex` модуля нет (ADR-0064).
if Code.ensure_loaded?(OpenApiSpex) do
  defmodule Core.Web.Response.Schema.Error do
    @moduledoc """
    OpenAPI-схема `ErrorResponse` — тело `Core.Web.Response.error/2,3`.

    Одна схема на все статусы ошибки (ADR-0065): `code` — строка без перечисления, `data` —
    открытый объект, состав множества ошибок — необязательный `data.errors` (`Core.Web.ErrorMapper`).
    Не через `OpenApiSpex.schema/2` (`10-architecture.md`, «OpenAPI-схемы wire»).
    """

    @behaviour OpenApiSpex.Schema

    @schema OpenApiSpex.build_schema(
              %{
                title: "ErrorResponse",
                description: "Ответ с ошибкой",
                type: :object,
                properties: %{
                  status: %OpenApiSpex.Schema{type: :string, enum: ["error"]},
                  data: %OpenApiSpex.Schema{
                    type: :object,
                    description: "Данные ошибки; у множества ошибок — его состав в `errors`",
                    properties: %{
                      errors: %OpenApiSpex.Schema{
                        type: :array,
                        items: %OpenApiSpex.Schema{
                          type: :object,
                          properties: %{
                            code: %OpenApiSpex.Schema{type: :string, description: "Код ошибки"},
                            message: %OpenApiSpex.Schema{type: :string, description: "Текст для человека"}
                          },
                          required: ~w(code message)a
                        }
                      }
                    }
                  },
                  code: %OpenApiSpex.Schema{type: :string, description: "Код ошибки"},
                  message: %OpenApiSpex.Schema{type: :string, description: "Текст для человека"}
                },
                required: ~w(status data code message)a,
                example: %{
                  "status" => "error",
                  "data" => %{
                    "errors" => [
                      %{"code" => "blank", "message" => "Имя не заполнено"},
                      %{"code" => "past", "message" => "Срок в прошлом"}
                    ]
                  },
                  "code" => "invalid",
                  "message" => "Форма заполнена с ошибками"
                }
              },
              struct?: false
            )

    @doc "OpenAPI-схема ответа с ошибкой."
    @spec schema() :: OpenApiSpex.Schema.t()

    @impl true
    def schema, do: @schema
  end
end
