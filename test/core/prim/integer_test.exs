defmodule Core.Prim.IntegerTest do
  use ExUnit.Case, async: true

  defmodule Age do
    use Core.Prim.Integer, name: "Возраст", min: 0, max: 120
  end

  defmodule Tight do
    use Core.Prim.Integer, name: "Узкий", min: 0, sec_max_len: 3
  end

  defmodule Score do
    use Core.Prim.Integer,
      name: "Балл",
      min: 0,
      kind: :score,
      mutate: &Core.Prim.IntegerTest.clamp/1,
      validate: &Core.Prim.IntegerTest.even/1
  end

  def clamp(value), do: min(value, 100)

  def even(value) when rem(value, 2) == 0, do: :ok
  def even(_value), do: {:error, {:odd, "только чётное"}}

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

  test "cast принимает знак и отвергает пробелы и дробь" do
    assert {:ok, %Age{value: 5}} = Age.new("+5")

    for raw <- ["5 ", " 5", "5.0", "5e1"] do
      assert {:error, %Core.Error{message: "Возраст: невалидное значение"}} = Age.new(raw)
    end
  end

  test "custom mutate применяется до validate" do
    assert {:ok, %Score{value: 100}} = Score.new(200)
  end

  test "custom validate возвращает свой код ошибки" do
    assert {:error, %Core.Error{kind: :domain, code: :odd, message: "Балл: только чётное"}} =
             Score.new(3)
  end

  test "custom kind сохраняется" do
    assert Score.__domain_kind__() == :score
  end

  describe "байтовая граница строкового ввода" do
    test "огромная строка цифр — доменная ошибка, а не SystemLimitError" do
      # ~2 млн цифр упираются в лимит BEAM на размер bignum: `Integer.parse/1`
      # поднял бы `SystemLimitError` мимо контракта `new/1`.
      huge = String.duplicate("9", 2_000_000)

      assert {:error, %Core.Error{kind: :domain, message: "Возраст: невалидное значение"}} =
               Age.new(huge)
    end

    test "default выводится из max и пропускает валидные записи" do
      assert Core.Prim.Integer.sec_max_len(min: 0, max: 120) == 7
      assert Core.Prim.Integer.sec_max_len(min: 1) == 40

      assert {:ok, %Age{value: 120}} = Age.new("+120")
      assert {:error, %Core.Error{}} = Age.new(String.duplicate("0", 8) <> "120")
    end

    test "явный sec_max_len перебивает выведенный" do
      assert {:ok, %Tight{value: 999}} = Tight.new("999")
      assert {:error, %Core.Error{message: "Узкий: невалидное значение"}} = Tight.new("1000")
    end

    test "integer на входе границей не ограничен" do
      assert {:ok, %Age{value: 120}} = Age.new(120)
    end
  end

  test "rejects sec_max_len below own max at compile time" do
    assert_raise CompileError, ~r/sec_max_len \(2\) меньше десятичной записи границ/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Prim.IntegerTest.TooTight do
            use Core.Prim.Integer, name: "X", max: 1000, sec_max_len: 2
          end
        end
      )
    end
  end

  test "rejects min > max at compile time" do
    assert_raise CompileError, ~r/min \(10\) больше max \(1\)/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Prim.IntegerTest.BadBounds do
            use Core.Prim.Integer, name: "X", min: 10, max: 1
          end
        end
      )
    end
  end

  test "rejects non-integer bound at compile time" do
    assert_raise CompileError, ~r/max: ожидается целое/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Prim.IntegerTest.BadBound do
            use Core.Prim.Integer, name: "X", max: "10"
          end
        end
      )
    end
  end
end
