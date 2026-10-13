defmodule Core.Web.ResponseTest do
  use ExUnit.Case, async: true

  alias Core.Pagination
  alias Core.Web.Response

  test "success без данных — пустой data" do
    assert Response.success() == %{status: "ok", data: %{}}
  end

  test "success с данными" do
    assert Response.success(%{id: "1"}) == %{status: "ok", data: %{id: "1"}}
  end

  test "error — код строкой, текст и пустой data" do
    assert Response.error(:invalid, "нельзя") ==
             %{status: "error", data: %{}, code: "invalid", message: "нельзя"}
  end

  test "error с данными" do
    assert Response.error(:invalid, "нельзя", %{errors: []}) ==
             %{status: "error", data: %{errors: []}, code: "invalid", message: "нельзя"}
  end

  test "page прогоняет элементы через presenter" do
    page = %Pagination.Result{items: [%{id: 1}, %{id: 2}], count: 7}

    assert Response.page_data(page, &%{"id" => &1.id}) == %{
             items: [%{"id" => 1}, %{"id" => 2}],
             total: 7
           }
  end
end
