defmodule Core.Web.Params.SchemaTest do
  use ExUnit.Case, async: true

  alias Core.Pagination
  alias Core.Web.Params
  alias OpenApiSpex.Cast
  alias OpenApiSpex.Parameter

  test "page/1 — limit и offset в query, необязательные, с границами Prim" do
    assert [
             %Parameter{name: :limit, in: :query, required: false, schema: limit},
             %Parameter{name: :offset, in: :query, required: false, schema: offset}
           ] = Params.Schema.page()

    assert %{type: :integer, minimum: 1, maximum: 100} = limit
    assert %{type: :integer, minimum: 0, maximum: nil} = offset
  end

  test "умолчания схемы совпадают с умолчаниями Params.page/2 при тех же опциях" do
    for opts <- [[], [limit_default: 24, offset_default: 5]] do
      [%Parameter{schema: limit}, %Parameter{schema: offset}] = Params.Schema.page(opts)
      {:ok, {parsed_limit, parsed_offset}} = Params.page(%{}, opts)

      assert limit.default == Pagination.Limit.value(parsed_limit)
      assert offset.default == Pagination.Offset.value(parsed_offset)
    end
  end

  test "значение за границей Pagination.Limit отклоняет схема параметра" do
    [%Parameter{schema: limit} | _] = Params.Schema.page()

    assert {:ok, 100} = Cast.cast(limit, 100)
    assert {:error, _} = Cast.cast(limit, 101)
    assert {:error, _} = Cast.cast(limit, 0)
  end

  test "опции — схема Params.page/2: неизвестный ключ — ArgumentError" do
    assert_raise ArgumentError, ~r/^Core\.Web\.Params\.Schema\.page\/1: /, fn ->
      Params.Schema.page(limit: 24)
    end
  end
end
