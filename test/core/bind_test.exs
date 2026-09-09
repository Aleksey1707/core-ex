defmodule Core.BindTest do
  use ExUnit.Case, async: true

  import Core.Bind

  defmodule Fixture do
    @moduledoc false

    def one(value, fun), do: fun.(value)
    def two(a, b, fun), do: fun.(a, b)
    def zero(fun), do: fun.()
    def middle(value, fun, opts), do: fun.({value, opts})
    def result(value, fun), do: fun.({:ok, value})
  end

  test "паттерн слева даёт одноарный колбэк, шаги вкладываются друг в друга" do
    value =
      bind do
        x <- Fixture.one(1)
        y <- Fixture.one(2)
        x + y
      end

    assert value == 3
  end

  test "пустой список слева даёт нуль-арный колбэк" do
    value =
      bind do
        [] <- Fixture.zero()
        :done
      end

    assert value == :done
  end

  test "список слева даёт колбэк по числу элементов" do
    value =
      bind do
        [a, b] <- Fixture.two(1, 2)
        a * b
      end

    assert value == 2
  end

  test "одноэлементный список слева равен голому паттерну" do
    value =
      bind do
        [x] <- Fixture.one(1)
        x + 1
      end

    assert value == 2
  end

  test "список-паттерн слева матчится вложенным списком параметров" do
    value =
      bind do
        [[a, b]] <- Fixture.one([1, 2])
        a + b
      end

    assert value == 3
  end

  test "паттерн слева матчится как есть" do
    value =
      bind do
        {:ok, x} <- Fixture.result(:payload)
        x
      end

    assert value == :payload
  end

  test "маркер `_` задаёт позицию колбэка среди аргументов" do
    value =
      bind do
        x <- Fixture.middle(1, _, opts: true)
        x
      end

    assert value == {1, [opts: true]}
  end

  test "pipe справа разворачивается в вызов" do
    value =
      bind do
        x <- 2 |> Fixture.one()
        x + 1
      end

    assert value == 3
  end

  test "строка без `<-` остаётся выражением на своём месте" do
    value =
      bind do
        x <- Fixture.one(1)
        y = x + 1
        z <- Fixture.one(y)
        z * 2
      end

    assert value == 4
  end

  test "колбэк замыкает внешние переменные" do
    outer = 10

    value =
      bind do
        x <- Fixture.one(1)
        outer + x
      end

    assert value == 11
  end

  test "блок без `<-` вычисляется как есть" do
    assert bind(do: 1 + 1) == 2
  end

  test "пустой блок даёт nil" do
    value =
      bind do
      end

    assert value == nil
  end

  test "pipe-цепочка разворачивается, колбэк уходит в последнее звено" do
    value =
      bind do
        x <-
          [1, 2]
          |> Enum.sum()
          |> Fixture.one()

        x
      end

    assert value == 3
  end

  test "справа допустим вызов анонимной функции" do
    fun = fn value, cb -> cb.(value) end

    value =
      bind do
        x <- fun.(5)
        x + 1
      end

    assert value == 6
  end

  test "вложенный bind допустим в теле шага" do
    value =
      bind do
        x <- Fixture.one(1)

        inner =
          bind do
            y <- Fixture.one(2)
            y * 10
          end

        x + inner
      end

    assert value == 21
  end

  test "`<-` внутри вложенного with не перехватывается" do
    value =
      bind do
        [] <- Fixture.zero()

        with {:ok, x} <- Map.fetch(%{a: 1}, :a) do
          x
        end
      end

    assert value == 1
  end

  test "сигил справа — CompileError" do
    assert_raise CompileError, ~r/не сигил/, fn ->
      eval("""
      bind do
        _x <- ~w(a b)a
        :ok
      end
      """)
    end
  end

  test "оператор справа — CompileError" do
    assert_raise CompileError, ~r/не оператор/, fn ->
      eval("""
      bind do
        _x <- 1 + 2
        :ok
      end
      """)
    end
  end

  test "форма с do-блоком справа — CompileError" do
    assert_raise CompileError, ~r/не форма с `do`-блоком/, fn ->
      eval("""
      bind do
        _x <- if(true, do: 1)
        :ok
      end
      """)
    end
  end

  test "вложенный bind справа от `<-` — CompileError" do
    assert_raise CompileError, ~r/не форма с `do`-блоком/, fn ->
      eval("""
      bind do
        _x <-
          bind do
            _y <- Core.BindTest.Fixture.one(1)
            :ok
          end

        :ok
      end
      """)
    end
  end

  test "guard слева сохраняется при одном параметре" do
    value =
      bind do
        x when is_integer(x) <- Fixture.one(1)
        x
      end

    assert value == 1
  end

  test "guard слева не схлопывает список параметров в один" do
    value =
      bind do
        [a, b] when a < b <- Fixture.two(1, 2)
        a + b
      end

    assert value == 3
  end

  test "промах паттерна слева падает — else у bind нет" do
    assert_raise FunctionClauseError, fn ->
      bind do
        {:ok, x} <- Fixture.one(:boom)
        x
      end
    end
  end

  test "блок с else — CompileError" do
    assert_raise CompileError, ~r/принимается только `do`-блок/, fn ->
      eval("""
      bind do
        x <- Core.BindTest.Fixture.one(1)
        x
      else
        _other -> :error
      end
      """)
    end
  end

  test "`<-` последним выражением — CompileError" do
    assert_raise CompileError, ~r/связывать нечего/, fn ->
      eval("""
      bind do
        _x <- Core.BindTest.Fixture.one(1)
      end
      """)
    end
  end

  test "справа не вызов — CompileError" do
    assert_raise CompileError, ~r/ожидается вызов функции/, fn ->
      eval("""
      bind do
        _x <- :value
        :ok
      end
      """)
    end
  end

  test "два маркера `_` — CompileError" do
    assert_raise CompileError, ~r/допустим только один/, fn ->
      eval("""
      bind do
        _x <- Core.BindTest.Fixture.middle(_, _, opts: true)
        :ok
      end
      """)
    end
  end

  # ---

  defp eval(source), do: Code.eval_string("import Core.Bind\n" <> source, [], __ENV__)
end
