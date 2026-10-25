defmodule Core.Web.ApiSpecCaseTest do
  use ExUnit.Case, async: true

  alias Core.Web.ApiSpecCase
  alias Core.WebApiSpecFixture
  alias OpenApiSpex.Components
  alias OpenApiSpex.Info
  alias OpenApiSpex.MediaType
  alias OpenApiSpex.OpenApi
  alias OpenApiSpex.Operation
  alias OpenApiSpex.PathItem
  alias OpenApiSpex.Reference
  alias OpenApiSpex.RequestBody
  alias OpenApiSpex.Schema

  defmodule PagedFilter do
    @moduledoc false

    @behaviour OpenApiSpex.Schema

    @impl true
    def schema do
      %Schema{
        title: "PagedFilter",
        type: :object,
        properties: %{"filter" => %Schema{type: :object}, "limit" => %Schema{type: :integer}}
      }
    end
  end

  describe "опции" do
    test "async: не boolean — CompileError" do
      assert_raise CompileError, ~r/async/, fn ->
        Code.compile_string(~s|defmodule BadApiSpecAsync do\n use Core.Web.ApiSpecCase, otp_app: :core, async: 1\nend|)
      end
    end

    test "опечатка в ключе — при раскрытии, с меткой" do
      assert_raise CompileError, ~r/^Web\.ApiSpecCase: неизвестные опции: \[:otp_ap\]$/, fn ->
        Code.compile_string(~s|defmodule BadApiSpecKey do\n use Core.Web.ApiSpecCase, otp_app: :core, otp_ap: :x\nend|)
      end
    end
  end

  describe "specs!/1" do
    test "находит модули с @behaviour OpenApiSpex.OpenApi" do
      assert {WebApiSpecFixture.ApiSpec, %OpenApi{}} =
               List.keyfind(ApiSpecCase.specs!(:core), WebApiSpecFixture.ApiSpec, 0)

      refute List.keyfind(ApiSpecCase.specs!(:core), WebApiSpecFixture.Filter, 0)
    end

    test "приложение не загружено — ArgumentError" do
      assert_raise ArgumentError, ~r/не загружено/, fn -> ApiSpecCase.specs!(:no_such_app) end
    end
  end

  describe "check_found/1" do
    test "пустой обход — провал" do
      assert {:error, :empty} = ApiSpecCase.check_found([])
      assert :ok = ApiSpecCase.check_found(ApiSpecCase.specs!(:core))
    end
  end

  describe "check_page_in_query/1" do
    test "страница в query, фильтр в теле — :ok" do
      assert :ok = ApiSpecCase.check_page_in_query([{WebApiSpecFixture.ApiSpec, WebApiSpecFixture.ApiSpec.spec()}])
    end

    test "страница в теле — операция и поле" do
      body = %Schema{type: :object, properties: %{filter: %Schema{type: :object}, limit: %Schema{type: :integer}}}

      assert {:error, %{page_in_body: [{Spec, :post, "/orders/search", "limit"}]}} =
               ApiSpecCase.check_page_in_query([{Spec, spec(body)}])
    end

    test "схема тела разворачивается по модулю, ссылке на компонент и allOf" do
      offset = %Schema{type: :object, properties: %{"offset" => %Schema{type: :integer}}}
      components = %Components{schemas: %{"Offset" => offset}}
      body = %Schema{allOf: [PagedFilter, %Reference{"$ref": "#/components/schemas/Offset"}]}

      assert {:error, %{page_in_body: found}} = ApiSpecCase.check_page_in_query([{Spec, spec(body, components)}])
      assert found == [{Spec, :post, "/orders/search", "limit"}, {Spec, :post, "/orders/search", "offset"}]
    end

    test "тело по ссылке на requestBodies — тоже проверяется" do
      body = %RequestBody{content: %{"application/json" => %MediaType{schema: PagedFilter}}}
      components = %Components{requestBodies: %{"Search" => body}}

      spec =
        put_in(spec(nil, components).paths["/orders/search"].post.requestBody, %Reference{
          "$ref": "#/components/requestBodies/Search"
        })

      assert {:error, %{page_in_body: [{Spec, :post, "/orders/search", "limit"}]}} =
               ApiSpecCase.check_page_in_query([{Spec, spec}])
    end

    test "операция без тела — :ok" do
      assert :ok = ApiSpecCase.check_page_in_query([{Spec, spec(nil)}])
    end
  end

  defp spec(schema, components \\ nil) do
    body = if schema, do: %RequestBody{content: %{"application/json" => %MediaType{schema: schema}}}

    %OpenApi{
      info: %Info{title: "T", version: "1"},
      components: components,
      paths: %{"/orders/search" => %PathItem{post: %Operation{requestBody: body, responses: %{}}}}
    }
  end
end

defmodule Core.Web.ApiSpecCaseUseTest do
  use Core.Web.ApiSpecCase,
    otp_app: :core,
    async: true
end
