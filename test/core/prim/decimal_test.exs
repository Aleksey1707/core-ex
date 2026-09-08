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

  defmodule Tight do
    use Core.Prim.Decimal, name: "Узкая", min: 0, sec_max_len: 4
  end

  defmodule Rate do
    use Core.Prim.Decimal,
      name: "Ставка",
      scale: 2,
      kind: :rate,
      mutate: &Decimal.abs/1,
      validate: &Core.Prim.DecimalTest.not_zero/1
  end

  def not_zero(value) do
    if Decimal.eq?(value, 0),
      do: {:error, {:zero, "не может быть нулём"}},
      else: :ok
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

  test "custom mutate применяется до validate" do
    assert {:ok, %Rate{} = rate} = Rate.new("-1.50")
    assert Decimal.eq?(Rate.value(rate), Decimal.new("1.50"))
  end

  test "custom validate возвращает свой код ошибки" do
    assert {:error,
            %Core.Error{kind: :domain, code: :zero, message: "Ставка: не может быть нулём"}} =
             Rate.new(0)
  end

  test "custom kind сохраняется" do
    assert Rate.__domain_kind__() == :rate
  end

  describe "байтовая граница строкового ввода" do
    test "огромная строка цифр отсекается до разбора" do
      huge = String.duplicate("9", 2_000_000)

      assert {:error, %Core.Error{kind: :domain, message: "Сумма: невалидное значение"}} =
               Amount.new(huge)
    end

    test "default учитывает max и scale" do
      assert Core.Prim.Decimal.sec_max_len(min: 0, max: 100, scale: 2) == 13
      assert Core.Prim.Decimal.sec_max_len(min: 0) == 64

      assert {:ok, %Amount{}} = Amount.new("100.00")
      assert {:ok, %Amount{}} = Amount.new("1.0e2")
    end

    test "явный sec_max_len перебивает выведенный" do
      assert {:ok, %Tight{}} = Tight.new("9.99")
      assert {:error, %Core.Error{message: "Узкая: невалидное значение"}} = Tight.new("99.999")
    end

    test "%Decimal{} на входе границей не ограничен" do
      assert {:ok, %Amount{}} = Amount.new(Decimal.new("99.99"))
    end
  end

  test "rejects sec_max_len below own max at compile time" do
    assert_raise CompileError, ~r/sec_max_len \(2\) меньше записи границ со scale/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Prim.DecimalTest.TooTight do
            use Core.Prim.Decimal, name: "X", max: 1000, scale: 2, sec_max_len: 2
          end
        end
      )
    end
  end

  test "rejects negative scale at compile time" do
    assert_raise CompileError, ~r/scale: ожидается целое ≥ 0/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Prim.DecimalTest.BadScale do
            use Core.Prim.Decimal, name: "X", scale: -1
          end
        end
      )
    end
  end

  test "rejects non-decimal bound at compile time" do
    assert_raise CompileError, ~r/min: ожидается число, строку или %Decimal\{\}/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Prim.DecimalTest.BadBound do
            use Core.Prim.Decimal, name: "X", min: :zero
          end
        end
      )
    end
  end

  test "rejects min > max at compile time" do
    assert_raise CompileError, ~r/min \("10"\) больше max \(1\)/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Prim.DecimalTest.BadBounds do
            use Core.Prim.Decimal, name: "X", min: "10", max: 1
          end
        end
      )
    end
  end
end
