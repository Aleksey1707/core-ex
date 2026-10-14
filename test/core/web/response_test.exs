defmodule Core.Web.ResponseTest do
  use ExUnit.Case, async: true

  alias Core.Error
  alias Core.Pagination
  alias Core.Web.Response

  require Error

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

  test "error не принимает nil и boolean кодом" do
    for code <- [nil, true, false] do
      assert_raise FunctionClauseError, fn -> Response.error(code, "нельзя") end
    end
  end

  describe "error/1 — доменная ошибка" do
    test "код — ns/code, текст — message, пустой data" do
      error = Error.domain(code: :not_found, ns: :account, message: "Счёт не найден")

      assert Response.error(error) ==
               %{status: "error", data: %{}, code: "account/not_found", message: "Счёт не найден"}
    end

    test "множество ошибок — состав в data.errors, у каждого элемента свой ns" do
      error =
        Error.many(
          code: :invalid,
          ns: :form,
          message: "форма невалидна",
          errors: [
            Error.domain(code: :max_len, ns: :prim, message: "имя длинное"),
            Error.domain(code: :name_taken, ns: :account, message: "имя занято")
          ]
        )

      errors = [
        %{code: "prim/max_len", message: "имя длинное"},
        %{code: "account/name_taken", message: "имя занято"}
      ]

      assert Response.error(error) ==
               %{status: "error", data: %{errors: errors}, code: "form/invalid", message: "форма невалидна"}
    end
  end

  test "page прогоняет элементы через presenter" do
    page = %Pagination.Result{items: [%{id: 1}, %{id: 2}], total: 7}

    assert Response.page_data(page, &%{"id" => &1.id}) == %{
             items: [%{"id" => 1}, %{"id" => 2}],
             total: 7
           }
  end
end
