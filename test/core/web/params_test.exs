defmodule Core.Web.ParamsTest do
  use ExUnit.Case, async: true

  alias Core.Error
  alias Core.Exc
  alias Core.Pagination
  alias Core.Version
  alias Core.Web

  test "find читает atom- и одноимённый string-ключ" do
    assert Web.Params.find(%{limit: 5}, :limit) == 5
    assert Web.Params.find(%{"limit" => 5}, :limit) == 5
    assert Web.Params.find(%{}, :limit) == nil
  end

  test "find с default подставляет его на отсутствующем ключе" do
    assert Web.Params.find(%{}, :limit, 10) == 10
    assert Web.Params.find(%{"limit" => 5}, :limit, 10) == 5
  end

  test "get отдаёт доменную ошибку на отсутствующем параметре" do
    assert {:ok, "имя"} = Web.Params.get(%{"name" => "имя"}, :name)

    assert {:error, %Error{kind: :domain, ns: :web, code: :missing_param, detail: :name}} =
             Web.Params.get(%{}, :name)
  end

  test "get! поднимает Exc на отсутствующем параметре" do
    assert Web.Params.get!(%{name: "имя"}, :name) == "имя"

    assert_raise Exc, fn -> Web.Params.get!(%{}, :name) end
  end

  test "page разбирает limit/offset и подставляет дефолты" do
    assert {:ok, {%Pagination.Limit{value: 5}, %Pagination.Offset{value: 20}}} =
             Web.Params.page(%{"limit" => 5, "offset" => 20})

    assert {:ok, {%Pagination.Limit{value: 10}, %Pagination.Offset{value: 0}}} =
             Web.Params.page(%{})

    assert {:ok, {%Pagination.Limit{value: 50}, %Pagination.Offset{value: 7}}} =
             Web.Params.page(%{}, limit_default: 50, offset_default: 7)
  end

  test "page отдаёт доменную ошибку на значении вне границ" do
    assert {:error, %Error{kind: :domain}} = Web.Params.page(%{"limit" => 1000})
    assert {:error, %Error{kind: :domain}} = Web.Params.page(%{"offset" => -1})
  end

  test "version разбирает If-Match, включая `*`" do
    assert {:ok, :current} = Web.Params.version(%{"If-Match" => "*"})
    assert {:ok, %Version{value: 3}} = Web.Params.version(%{"If-Match" => "3"})

    assert {:error, %Error{code: :missing_param}} = Web.Params.version(%{})
    assert {:error, %Error{kind: :domain}} = Web.Params.version(%{"If-Match" => "мусор"})
  end

  test "version принимает свой ключ" do
    assert {:ok, :current} = Web.Params.version(%{version: "*"}, :version)
  end
end
