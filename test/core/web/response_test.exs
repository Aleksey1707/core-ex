defmodule Core.Web.ResponseTest do
  use ExUnit.Case, async: true

  alias Core.Error
  alias Core.Pagination
  alias Core.Web.Response

  require Error

  test "коды конверта round-trip по всем значениям" do
    for value <- Response.Code.values() do
      assert {:ok, ^value} = Response.Code.from_code(Response.Code.to_code(value))
    end
  end

  test "известные коды конверта соответствуют контракту API" do
    assert Response.Code.to_code(:success) == 0
    assert Response.Code.to_code(:domain_error) == 2
    assert Response.Code.to_code(:diff_version) == 3
    assert Response.Code.to_code(:auth_error) == 254
    assert Response.Code.to_code(:critical) == 255
  end

  test "values упорядочены по коду" do
    assert Response.Code.values() ==
             ~w(success error domain_error diff_version auth_error critical)a
  end

  test "success без данных и с данными" do
    assert Response.success() == %{code: 0, messages: []}
    assert Response.success(%{id: "1"}) == %{code: 0, messages: [], data: %{id: "1"}}
  end

  test "error кладёт текст в messages" do
    assert Response.error(:domain_error, "нельзя") == %{code: 2, messages: ["нельзя"]}
  end

  describe "свой словарь кодов" do
    defmodule Code do
      @moduledoc """
      Код статуса конверта потребителя
      """

      import Core.Helper.String, only: [first_line: 1]

      use Core.Enum,
        name: first_line(@moduledoc),
        codes: Map.merge(Response.Code.codes(), %{not_found: 4, conflict: 5})
    end

    defmodule CustomResponse do
      @moduledoc false

      use Core.Web.Response, codes: Core.Web.ResponseTest.Code
    end

    test "словарь собирается поверх базового, базовые коды не меняются" do
      assert Code.to_code(:domain_error) == Response.Code.to_code(:domain_error)
      assert Code.to_code(:not_found) == 4
      assert Code.values() -- Response.Code.values() == ~w(not_found conflict)a
    end

    test "конверт отдаёт коды своего словаря" do
      assert CustomResponse.error(:not_found, "нет") == %{code: 4, messages: ["нет"]}
      assert CustomResponse.error(:domain_error, "нельзя") == %{code: 2, messages: ["нельзя"]}
      assert CustomResponse.success(%{id: "1"}) == %{code: 0, messages: [], data: %{id: "1"}}
      assert CustomResponse.success() == %{code: 0, messages: []}
    end

    test "конверт принимает результат ErrorMapper" do
      error = Error.domain(code: :boom, ns: :test, message: "бум")
      {_status, code, message, _level} = Core.Web.ErrorMapper.map(error)

      assert CustomResponse.error(code, message) == %{code: 2, messages: ["бум"]}
    end

    test "page генерируется вместе с остальным конвертом" do
      page = %Pagination.Result{items: [%{id: 1}], count: 1}

      assert CustomResponse.page(page, &%{"id" => &1.id}) == %{count: 1, items: [%{"id" => 1}]}
    end

    test "словарь без базовых значений отвергается на компиляции" do
      assert_raise CompileError, ~r/не покрывает базовые значения/, fn ->
        Elixir.Code.eval_quoted(
          quote do
            defmodule Core.Web.ResponseTest.Narrow do
              use Core.Enum, name: "Узкий", codes: %{success: 0, error: 1}
            end

            defmodule Core.Web.ResponseTest.NarrowResponse do
              use Core.Web.Response, codes: Core.Web.ResponseTest.Narrow
            end
          end
        )
      end
    end

    test "словарь со строковыми кодами отвергается на компиляции" do
      assert_raise CompileError, ~r/целочисленные коды/, fn ->
        Elixir.Code.eval_quoted(
          quote do
            defmodule Core.Web.ResponseTest.Strings do
              use Core.Enum,
                name: "Строковый",
                codes: %{
                  success: "OK",
                  error: "ERR",
                  domain_error: "DOM",
                  diff_version: "VER",
                  auth_error: "AUTH",
                  critical: "CRIT"
                }
            end

            defmodule Core.Web.ResponseTest.StringsResponse do
              use Core.Web.Response, codes: Core.Web.ResponseTest.Strings
            end
          end
        )
      end
    end

    test "неизвестная опция билдера отвергается на компиляции" do
      assert_raise CompileError, ~r/unknown option\(s\): \[:foo\]/, fn ->
        Elixir.Code.eval_quoted(
          quote do
            defmodule Core.Web.ResponseTest.BadOpts do
              use Core.Web.Response, codes: Core.Web.ResponseTest.Code, foo: 1
            end
          end
        )
      end
    end
  end

  test "page прогоняет элементы через presenter" do
    page = %Pagination.Result{items: [%{id: 1}, %{id: 2}], count: 7}

    assert Response.page(page, &%{"id" => &1.id}) == %{
             count: 7,
             items: [%{"id" => 1}, %{"id" => 2}]
           }
  end
end
