defmodule Core.Pagination.ResultTest do
  use ExUnit.Case, async: true

  alias Core.Pagination.Result

  test "new/2 builds result with items and count" do
    assert %Result{items: [1, 2], count: 10} = Result.new([1, 2], 10)
  end

  test "empty/0 — пустая страница" do
    assert %Result{items: [], count: 0} = Result.empty()
  end

  test "map/2 меняет элементы, но не count всей выборки" do
    page = Result.new([1, 2], 10)

    assert %Result{items: [2, 4], count: 10} = Result.map(page, &(&1 * 2))
  end
end
