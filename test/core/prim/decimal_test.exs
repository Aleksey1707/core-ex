defmodule Core.Prim.DecimalTest do
  use ExUnit.Case, async: true

  defmodule Amount do
    use Core.Prim.Decimal, name: "Сумма", min: 0, max: 100, scale: 2
  end

  defmodule Quantity do
    use Core.Prim.Decimal, name: "Количество", min: 0, scale: 3
  end

  defmodule Whole do
    use Core.Prim.Decimal, name: "Целое", min: 0, scale: 0
  end

  defmodule Unbounded do
    use Core.Prim.Decimal, name: "Без границ"
  end

  test "casts Decimal, integer, float, binary" do
    assert {:ok, %Amount{value: %Decimal{}}} = Amount.new(Decimal.new("10.5"))
    assert {:ok, %Amount{}} = Amount.new(10)
    assert {:ok, %Amount{}} = Amount.new(10.5)
    assert {:ok, %Amount{}} = Amount.new("10.50")
  end

  test "rejects invalid cast as domain error" do
    assert {:error, %Core.Error{kind: :domain, message: "Сумма: невалидное значение"}} =
             Amount.new("abc")
  end

  test "validates min with russian message" do
    assert {:error, %Core.Error{kind: :domain, message: "Сумма: от 0 до 100"}} =
             Amount.new("-1")
  end

  test "validates max" do
    assert {:error, %Core.Error{kind: :domain, message: "Сумма: от 0 до 100"}} =
             Amount.new("101")
  end

  test "validates scale" do
    assert {:error, %Core.Error{kind: :domain, code: :scale}} =
             Amount.new("1.234")
  end

  test "accepts trailing zeros within scale" do
    assert {:ok, %Quantity{}} = Quantity.new("3")
    assert {:ok, %Quantity{}} = Quantity.new("3.000")
    assert {:ok, %Quantity{}} = Quantity.new("3.000000")
    assert {:ok, %Quantity{}} = Quantity.new(%Decimal{coef: 3_000_000, exp: -6, sign: 1})
    assert {:ok, %Amount{}} = Amount.new("10.5")
    assert {:ok, %Amount{}} = Amount.new("10.50")
  end

  test "rejects significant digits beyond scale" do
    assert {:error, %Core.Error{kind: :domain, code: :scale}} =
             Quantity.new("3.0001")
  end

  test "scale 0 accepts integers with trailing zeros and rejects fractions" do
    assert {:ok, %Whole{}} = Whole.new("5")
    assert {:ok, %Whole{}} = Whole.new("5.000")

    assert {:error, %Core.Error{kind: :domain, code: :scale}} =
             Whole.new("5.1")
  end

  test "new!/1 and value/1" do
    amount = Amount.new!("12.34")
    assert Decimal.eq?(Amount.value(amount), Decimal.new("12.34"))
  end

  # `Decimal.new/1` парсит эти литералы без исключения, а `Decimal.compare/2` на них
  # поднимает `Decimal.Error` из дефолтного контекста — мимо контракта `new/1`.
  test "не-финитные значения отвергаются доменной ошибкой" do
    for raw <- ~w(NaN nan Infinity -Infinity inf -inf) do
      assert {:error, %Core.Error{kind: :domain, code: :invalid_decimal}} =
               Amount.new(raw),
             "ожидалась доменная ошибка для #{raw}"
    end
  end

  test "не-финитный %Decimal{} на входе тоже отвергается" do
    assert {:error, %Core.Error{kind: :domain, code: :invalid_decimal}} =
             Amount.new(Decimal.new("NaN"))

    assert {:error, %Core.Error{kind: :domain, code: :invalid_decimal}} =
             Quantity.new(Decimal.new("Infinity"))
  end

  test "Prim без min/max тоже не пропускает не-финитные" do
    assert {:error, %Core.Error{code: :invalid_decimal}} = Unbounded.new("NaN")
    assert {:error, %Core.Error{code: :invalid_decimal}} = Unbounded.new("Infinity")
  end
end
