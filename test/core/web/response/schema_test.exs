defmodule Core.Web.Response.SchemaTest do
  use ExUnit.Case, async: true

  import OpenApiSpex.TestAssertions

  alias Core.Error
  alias Core.Pagination
  alias Core.Web.ErrorMapper
  alias Core.Web.Response
  alias OpenApiSpex.Components
  alias OpenApiSpex.Info
  alias OpenApiSpex.MediaType
  alias OpenApiSpex.OpenApi
  alias OpenApiSpex.Operation
  alias OpenApiSpex.PathItem
  alias OpenApiSpex.Reference

  require Error

  defmodule Item do
    @moduledoc false

    @behaviour OpenApiSpex.Schema

    @impl true
    def schema do
      %OpenApiSpex.Schema{
        title: "Item",
        type: :object,
        properties: %{id: %OpenApiSpex.Schema{type: :string}},
        required: [:id]
      }
    end
  end

  describe "успех и страница" do
    test "success/0,1 проходят свои схемы" do
      assert {:ok, _} = cast(Response.success(), Response.Schema.success())

      for data <- [Item, Item.schema(), %Reference{"$ref": "#/components/schemas/Item"}] do
        assert {:ok, _} = cast(Response.success(%{id: "1"}), Response.Schema.success(data)), inspect(data)
      end
    end

    test "страница page_data/2 под success/1 проходит page/1" do
      page = %Pagination.Result{items: [%{id: 1}, %{id: 2}], total: 7}

      for item <- [Item, Item.schema(), %Reference{"$ref": "#/components/schemas/Item"}] do
        body = Response.success(Response.page_data(page, &%{id: to_string(&1.id)}))

        assert {:ok, _} = cast(body, Response.Schema.page(item)), inspect(item)
      end
    end

    test "тело ошибки против схемы успеха — отказ" do
      error = Response.error(:invalid, "нельзя")

      assert {:error, _} = cast(error, Response.Schema.success())
      assert {:error, _} = cast(error, Response.Schema.success(Item))
    end

    test "страница без total — отказ" do
      assert {:error, _} = cast(Response.success(%{items: [%{id: "1"}]}), Response.Schema.page(Item))
    end

    test "схемы анонимные" do
      for schema <- [Response.Schema.success(), Response.Schema.success(Item), Response.Schema.page(Item)] do
        assert %OpenApiSpex.Schema{title: nil} = schema
      end
    end

    test "новое поле обёртки и данных страницы проходит схему" do
      assert {:ok, _} = cast(Map.put(Response.success(), :trace, "t"), Response.Schema.success())

      body = %{status: "ok", data: %{items: [], total: 0, cursor: "c"}, trace: "t"}

      assert {:ok, _} = cast(body, Response.Schema.page(Item))
    end
  end

  describe "ErrorResponse" do
    test "error/2,3 проходят схему" do
      assert_error(Response.error(:invalid, "нельзя"))
      assert_error(Response.error(:invalid, "нельзя", %{errors: [%{code: "blank", message: "имя пусто"}]}))
    end

    test "каждая строка ErrorMapper.map/2 проходит схему" do
      many =
        Error.many(
          code: :invalid,
          ns: :form,
          message: "форма невалидна",
          errors: [domain(:blank), domain(:past)]
        )

      for {reason, status} <- [
            {domain(:version_mismatch), 412},
            {domain(:access_denied), 403},
            {domain(:unauthorized), 401},
            {domain(:invalid), 400},
            {many, 400},
            {Error.app(code: :write_failed, ns: :test), 500},
            {:timeout, 500}
          ] do
        assert {^status, body, _level} = ErrorMapper.map(reason)
        assert_error(body)
      end
    end

    test "пример проходит свою схему" do
      %{example: example} = Response.Schema.error().schema()

      assert %{"data" => %{"errors" => [_ | _]}} = example
      assert_schema(example, "ErrorResponse", spec())
    end

    test "status не из перечисления и code числом — отказ" do
      %OpenApi{components: %Components{schemas: %{"ErrorResponse" => schema}}} = spec = spec()

      for body <- [
            %{"status" => "ok", "data" => %{}, "code" => "invalid", "message" => "нельзя"},
            %{"status" => "error", "data" => %{}, "code" => 400, "message" => "нельзя"}
          ] do
        assert {:error, _} = OpenApiSpex.cast_value(body, schema, spec), inspect(body)
      end
    end
  end

  # ---

  defp cast(body, schema) do
    %OpenApi{paths: %{"/" => %PathItem{get: operation}}} = spec = operation_spec(schema)
    %Operation{responses: %{200 => %{content: %{"application/json" => %MediaType{schema: resolved}}}}} = operation

    OpenApiSpex.cast_value(json(body), resolved, spec)
  end

  defp operation_spec(schema) do
    operation = %Operation{
      operationId: "show",
      responses: %{
        200 => %OpenApiSpex.Response{description: "Успех", content: %{"application/json" => %MediaType{schema: schema}}}
      }
    }

    OpenApiSpex.resolve_schema_modules(%{spec() | paths: %{"/" => %PathItem{get: operation}}})
    |> OpenApiSpex.add_schemas([Item])
  end

  defp assert_error(body), do: assert_schema(json(body), "ErrorResponse", spec())

  defp json(body), do: Jason.decode!(Jason.encode!(body))

  defp spec do
    OpenApiSpex.add_schemas(
      %OpenApi{
        info: %Info{title: "Core.Web.Response.SchemaTest", version: "0"},
        paths: %{},
        components: %Components{schemas: %{}}
      },
      [Response.Schema.error()]
    )
  end

  defp domain(code), do: Error.domain(code: code, ns: :test, message: "сообщение домена")
end
