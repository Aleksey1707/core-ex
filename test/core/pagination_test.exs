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

  test "Offset.new/1 отсекает огромную строку цифр доменной ошибкой" do
    # У `Offset` нет `max:`, а строка приходит прямо из query (`Core.Web.Params.page/2`):
    # без байтовой границы `Integer.parse/1` поднял бы `SystemLimitError`.
    assert {:error, %Error{kind: :domain, message: "Смещение страницы: невалидное значение"}} =
             Pagination.Offset.new(String.duplicate("9", 2_000_000))
  end
end
