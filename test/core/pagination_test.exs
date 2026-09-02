defmodule Core.PaginationTest do
  use ExUnit.Case, async: true

  alias Core.Error
  alias Core.Pagination

  test "Limit.new/1 accepts bounds 1..100" do
    assert {:ok, %Pagination.Limit{value: 1}} = Pagination.Limit.new(1)
    assert {:ok, %Pagination.Limit{value: 100}} = Pagination.Limit.new(100)
  end

  test "Limit.new/1 rejects below min and above max" do
    assert {:error, %Error{kind: :domain, message: "Размер страницы: от 1 до 100"}} =
             Pagination.Limit.new(0)

    assert {:error, %Error{kind: :domain, message: "Размер страницы: от 1 до 100"}} =
             Pagination.Limit.new(101)
  end

  test "Offset.new/1 accepts non-negative" do
    assert {:ok, %Pagination.Offset{value: 0}} = Pagination.Offset.new(0)
    assert {:ok, %Pagination.Offset{value: 10}} = Pagination.Offset.new(10)
  end

  test "Offset.new/1 rejects negative" do
    assert {:error, %Error{kind: :domain, message: "Смещение страницы: минимум 0"}} =
             Pagination.Offset.new(-1)
  end
end
