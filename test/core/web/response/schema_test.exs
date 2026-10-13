defmodule Core.Web.Response.SchemaTest do
  use ExUnit.Case, async: true

  import OpenApiSpex.TestAssertions

  alias Core.Error
  alias Core.Web.ErrorMapper
  alias Core.Web.Response
  alias OpenApiSpex.Components
  alias OpenApiSpex.Info
  alias OpenApiSpex.OpenApi

  require Error

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
