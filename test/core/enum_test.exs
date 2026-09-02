defmodule Core.EnumTest do
  use ExUnit.Case, async: true

  alias Core.Error
  alias Core.Exc

  defmodule Sample do
    @moduledoc false

    use Core.Enum,
      name: "Тестовый статус",
      values: ~w(new done)a
  end

  defmodule Coded do
    @moduledoc false

    use Core.Enum,
      name: "Справочник с кодами",
      codes: %{first: 1, second: 20}
  end

  defmodule StringCoded do
    @moduledoc false

    use Core.Enum,
      name: "Справочник со строковыми кодами",
      codes: %{weight: "WEIGHT", piece: "PIECE"}
  end

  defmodule DigitStringCoded do
    @moduledoc false

    use Core.Enum,
      name: "Справочник со строковыми кодами из цифр",
      codes: %{first: "1", second: "20"}
  end

  test "values/0 и name/0" do
    assert Sample.values() == [:new, :done]
    assert Sample.name() == "Тестовый статус"
  end

  test "member?/1" do
    assert Sample.member?(:new)
    assert Sample.member?(:done)
    refute Sample.member?(:failed)
    refute Sample.member?("new")
  end

  test "cast/1 принимает атом из values" do
    assert {:ok, :new} = Sample.cast(:new)
    assert {:ok, :done} = Sample.cast(:done)
  end

  test "cast/1 принимает binary-имя атома" do
    assert {:ok, :new} = Sample.cast("new")
    assert {:ok, :done} = Sample.cast("done")
  end

  test "cast/1 отклоняет неизвестные значения" do
    assert {:error, %Error{kind: :domain, ns: :enum, code: :invalid_value, module: Sample}} =
             Sample.cast(:failed)

    assert {:error, %Error{message: "Тестовый статус: недопустимое значение"}} =
             Sample.cast("failed")

    assert {:error, %Error{code: :invalid_value}} = Sample.cast(1)
  end

  test "cast!/1" do
    assert :new = Sample.cast!(:new)

    assert_raise Exc, fn ->
      Sample.cast!(:failed)
    end
  end

  test "cast_optional/1" do
    assert {:ok, nil} = Sample.cast_optional(nil)
    assert {:ok, :new} = Sample.cast_optional(:new)
    assert {:ok, :done} = Sample.cast_optional("done")
    assert {:error, %Error{code: :invalid_value}} = Sample.cast_optional(:failed)
  end

  test "compile-time: пустой values" do
    assert_raise CompileError, ~r/non-empty list of atoms/, fn ->
      Code.compile_quoted(
        quote do
          defmodule Core.EnumTest.EmptyValues do
            use Core.Enum,
              name: "x",
              values: []
          end
        end
      )
    end
  end

  test "compile-time: дубликаты в values" do
    assert_raise CompileError, ~r/duplicates/, fn ->
      Code.compile_quoted(
        quote do
          defmodule Core.EnumTest.DupValues do
            use Core.Enum,
              name: "x",
              values: [:a, :a]
          end
        end
      )
    end
  end

  test "dump/1 отдаёт wire-строку" do
    assert Sample.dump(:new) == "new"
    assert Sample.dump(nil) == nil
  end

  test "cast_optional!/1 — bang-вариант" do
    assert Sample.cast_optional!(nil) == nil
    assert Sample.cast_optional!("new") == :new
    assert_raise Exc, fn -> Sample.cast_optional!("nope") end
  end

  test "codes/0 отдаёт карту значение → код" do
    assert Coded.codes() == %{first: 1, second: 20}
  end

  test "to_code/1 и from_code/1 — round-trip по всем значениям" do
    for value <- Coded.values() do
      assert {:ok, ^value} = Coded.from_code(Coded.to_code(value))
    end
  end

  test "from_code/1 принимает код-строку" do
    assert {:ok, :second} = Coded.from_code("20")
  end

  test "from_code/1 на неизвестном коде — доменная ошибка" do
    assert {:error, %Error{code: :invalid_value, ns: :enum}} = Coded.from_code(99)
    assert {:error, %Error{code: :invalid_value}} = Coded.from_code("20x")
  end

  test "from_code!/1 — bang-вариант" do
    assert Coded.from_code!(1) == :first
    assert_raise Exc, fn -> Coded.from_code!(99) end
  end

  test "enum без codes: не объявляет from_code/1" do
    refute function_exported?(Sample, :from_code, 1)
    refute function_exported?(Sample, :codes, 0)
  end

  test "compile-time: дубликаты кодов" do
    assert_raise CompileError, ~r/duplicate codes/, fn ->
      Code.compile_quoted(
        quote do
          defmodule Core.EnumTest.DupCodes do
            use Core.Enum,
              name: "x",
              codes: %{a: 1, b: 1}
          end
        end
      )
    end
  end

  describe "строковые коды" do
    test "codes/0 и to_code/1 отдают строку" do
      assert StringCoded.codes() == %{weight: "WEIGHT", piece: "PIECE"}
      assert StringCoded.to_code(:weight) == "WEIGHT"
    end

    test "from_code/1 — round-trip по всем значениям" do
      for value <- StringCoded.values() do
        assert {:ok, ^value} = StringCoded.from_code(StringCoded.to_code(value))
      end
    end

    test "from_code/1 сверяет код точно, без нормализации регистра" do
      assert {:ok, :weight} = StringCoded.from_code("WEIGHT")
      assert {:error, %Error{code: :invalid_value}} = StringCoded.from_code("weight")
      assert {:error, %Error{code: :invalid_value}} = StringCoded.from_code(" WEIGHT")
    end

    test "неизвестный код — доменная ошибка" do
      assert {:error, %Error{code: :invalid_value, ns: :enum}} = StringCoded.from_code("нет")
    end

    test "from_code!/1 — bang-вариант" do
      assert StringCoded.from_code!("PIECE") == :piece
      assert_raise Exc, fn -> StringCoded.from_code!("нет") end
    end

    test "строковый код из цифр не приводится к числу" do
      assert {:ok, :second} = DigitStringCoded.from_code("20")
      assert_raise FunctionClauseError, fn -> DigitStringCoded.from_code(20) end
    end
  end

  describe "целочисленные коды: приведение строки" do
    test "число, пришедшее строкой, принимается" do
      assert {:ok, :second} = Coded.from_code("20")
    end

    test "нецелая строка — доменная ошибка, а не падение" do
      assert {:error, %Error{code: :invalid_value}} = Coded.from_code("20x")
      assert {:error, %Error{code: :invalid_value}} = Coded.from_code("")
    end

    test "код не того типа — ошибка программиста" do
      assert_raise FunctionClauseError, fn -> Coded.from_code(:second) end
    end
  end

  describe "values выводятся из codes" do
    test "values/0 перечисляет ключи карты, упорядоченные по коду" do
      assert Coded.values() == [:first, :second]
      assert StringCoded.values() == [:piece, :weight]
    end

    test "выведенные значения работают как обычные" do
      assert Coded.member?(:first)
      assert {:ok, :second} = Coded.cast("second")
      assert Coded.dump(:first) == "first"
    end

    test "порядок значений следует кодам, а не алфавиту" do
      defmodule OrderedByCode do
        @moduledoc false

        use Core.Enum,
          name: "Порядок по коду",
          codes: %{zebra: 1, alpha: 2}
      end

      assert OrderedByCode.values() == [:zebra, :alpha]
    end

    test "compile-time: ни values, ни codes" do
      assert_raise CompileError, ~r/требуется :values либо :codes/, fn ->
        Code.compile_quoted(
          quote do
            defmodule Core.EnumTest.NoSource do
              use Core.Enum, name: "x"
            end
          end
        )
      end
    end

    test "compile-time: values вместе с codes" do
      assert_raise CompileError, ~r/не задаётся вместе с :codes/, fn ->
        Code.compile_quoted(
          quote do
            defmodule Core.EnumTest.BothSources do
              use Core.Enum,
                name: "x",
                values: [:a],
                codes: %{a: 1}
            end
          end
        )
      end
    end
  end

  describe "compile-time проверки codes:" do
    test "смешанные типы кодов" do
      assert_raise CompileError, ~r/one type/, fn ->
        Code.compile_quoted(
          quote do
            defmodule Core.EnumTest.MixedCodes do
              use Core.Enum,
                name: "x",
                codes: %{a: 1, b: "two"}
            end
          end
        )
      end
    end

    test "пустая строка как код" do
      assert_raise CompileError, ~r/one type/, fn ->
        Code.compile_quoted(
          quote do
            defmodule Core.EnumTest.EmptyStringCode do
              use Core.Enum,
                name: "x",
                codes: %{a: ""}
            end
          end
        )
      end
    end

    test "код неподходящего типа" do
      assert_raise CompileError, ~r/one type/, fn ->
        Code.compile_quoted(
          quote do
            defmodule Core.EnumTest.AtomCode do
              use Core.Enum,
                name: "x",
                codes: %{a: :code}
            end
          end
        )
      end
    end

    test "дубликаты строковых кодов" do
      assert_raise CompileError, ~r/duplicate codes/, fn ->
        Code.compile_quoted(
          quote do
            defmodule Core.EnumTest.DupStringCodes do
              use Core.Enum,
                name: "x",
                codes: %{a: "same", b: "same"}
            end
          end
        )
      end
    end
  end
end
