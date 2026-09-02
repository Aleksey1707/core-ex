defmodule Core.Prim.IntegerTest do
  use ExUnit.Case, async: true

  defmodule Age do
    use Core.Prim.Integer, name: "Возраст", min: 0, max: 120
  end

  test "casts integer and binary" do
    assert {:ok, %Age{value: 30}} = Age.new(30)
    assert {:ok, %Age{value: 30}} = Age.new("30")
  end

  test "rejects invalid cast" do
    assert {:error, %Core.Error{kind: :domain, message: "Возраст: невалидное значение"}} =
             Age.new("30x")
  end

  test "validates min" do
    assert {:error, %Core.Error{kind: :domain, message: "Возраст: от 0 до 120"}} =
             Age.new(-1)
  end

  test "validates max" do
    assert {:error, %Core.Error{kind: :domain, message: "Возраст: от 0 до 120"}} =
             Age.new(121)
  end

  test "new!/1 and value/1" do
    assert 42 = Age.value(Age.new!(42))
  end
end
