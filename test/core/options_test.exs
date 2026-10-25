defmodule Core.OptionsTest do
  use ExUnit.Case, async: true

  defmodule Builder do
    @moduledoc false

    use Core.Options

    defmacro __using__(_opts) do
      quote do
        def generated(opts), do: opts
      end
    end
  end

  defmodule Plain do
    @moduledoc false

    use Builder
  end

  defmodule Subject do
    @moduledoc false

    use Core.Options

    @opts [size: 1]

    @opts_schema [
      size: [type: :pos_integer, default: 10, doc: "Размер."],
      mode: [type: {:in, ~w(fast slow)a}, doc: "Режим."]
    ]
    def run(subject, opts \\ []) when is_atom(subject) and is_list(opts), do: {subject, opts}

    def plain(opts), do: Keyword.get(opts, :anything, :none)

    @opts_schema [key: [type: :atom, required: true, doc: "Ключ."]]
    def pick(:first, opts), do: {:first, opts[:key]}
    def pick(:second, opts), do: {:second, opts[:key]}

    @opts_schema [limit: [type: :pos_integer, default: 1, doc: "Предел."]]
    def head(subject, opts \\ [])

    def head(%{} = subject, opts), do: {:map, subject, opts}
    def head(subject, opts) when is_atom(subject), do: {:atom, subject, opts}

    @opts_schema [limit: [type: :pos_integer, default: 1, doc: "Предел."]]
    def guarded(subject, opts) do
      Keyword.fetch!(opts, :limit) + subject
    rescue
      ArithmeticError -> :rescued
    end

    def own_attribute, do: @opts
  end

  describe "вызов функции со схемой" do
    test "проверенные опции доходят до тела с умолчаниями" do
      assert {:a, opts} = Subject.run(:a, mode: :fast)
      assert Enum.sort(opts) == [mode: :fast, size: 10]
    end

    test "пустые опции и опции по умолчанию головы дают умолчания" do
      assert Subject.run(:a, []) == {:a, [size: 10]}
      assert Subject.run(:a) == {:a, [size: 10]}
    end

    test "неизвестный ключ — ArgumentError с именем функции" do
      assert_raise ArgumentError, ~r/^Core\.OptionsTest\.Subject\.run\/2: unknown options \[:sise\]/, fn ->
        Subject.run(:a, sise: 1)
      end
    end

    test "значение не того типа — ArgumentError с именем функции" do
      assert_raise ArgumentError, ~r/^Core\.OptionsTest\.Subject\.run\/2: invalid value for :size option/, fn ->
        Subject.run(:a, size: 0)
      end
    end

    test "не keyword-список — ArgumentError с именем функции" do
      assert_raise ArgumentError, ~r/^Core\.OptionsTest\.Subject\.head\/2: ожидается keyword-список/, fn ->
        Subject.head(:a, [:limit])
      end
    end

    test "схема действует на все клаузы функции" do
      assert Subject.pick(:first, key: :a) == {:first, :a}
      assert Subject.pick(:second, key: :b) == {:second, :b}

      assert_raise ArgumentError, ~r/^Core\.OptionsTest\.Subject\.pick\/2: unknown options/, fn ->
        Subject.pick(:second, key: :b, other: 1)
      end
    end

    test "обязательный ключ проверяется и на пустых опциях" do
      assert_raise ArgumentError, ~r/^Core\.OptionsTest\.Subject\.pick\/2: required :key option not found/, fn ->
        Subject.pick(:first, [])
      end
    end

    test "голова без тела задаёт умолчание, схема — на полной арности" do
      assert Subject.head(:a) == {:atom, :a, [limit: 1]}
      assert Subject.head(%{}, limit: 2) == {:map, %{}, [limit: 2]}

      assert_raise ArgumentError, ~r/^Core\.OptionsTest\.Subject\.head\/2: unknown options/, fn ->
        Subject.head(:a, other: 1)
      end
    end

    test "отказ проверки не ловится rescue тела" do
      assert Subject.guarded(:a, []) == :rescued

      assert_raise ArgumentError, ~r/guarded\/2: invalid value for :limit option/, fn ->
        Subject.guarded(1, limit: :x)
      end
    end

    test "домен головы остаётся авторским" do
      assert_raise FunctionClauseError, fn -> Subject.run("a", []) end
    end
  end

  describe "модуль с use Core.Options" do
    test "функция без схемы работает как обычная" do
      assert Subject.plain(anything: 1) == 1
      assert Subject.plain([]) == :none
    end

    test "атрибут @opts автора не задевается" do
      assert Subject.own_attribute() == [size: 1]
    end

    test "def из quote такого модуля в модуле без use Core.Options — обычный def" do
      assert Plain.generated(any: 1) == [any: 1]
    end

    test "голова без тела с unquote-фрагментом — Kernel.def как есть" do
      [{module, _binary}] =
        Code.compile_string("""
        defmodule Core.OptionsTest.Fragment#{System.unique_integer([:positive])} do
          use Core.Options

          name = :f
          def unquote(name)(subject, opts \\\\ [])
          def unquote(name)(subject, opts), do: {subject, opts}
        end
        """)

      assert module.f(:a) == {:a, []}
    end
  end

  describe "ошибки объявления — CompileError" do
    test "некорректная схема" do
      assert_compile_error(~r/^Options: f\/1: @opts_schema: invalid NimbleOptions schema/, """
      @opts_schema [size: [type: :no_such_type, doc: "Размер."]]
      def f(opts), do: opts
      """)

      assert_compile_error(~r/^Options: f\/1: @opts_schema: invalid NimbleOptions schema/, """
      @opts_schema [size: [type: :integer, defualt: 1, doc: "Размер."]]
      def f(opts), do: opts
      """)

      assert_compile_error(~r/^Options: f\/1: @opts_schema: ожидается непустая keyword-схема/, """
      @opts_schema :size
      def f(opts), do: opts
      """)
    end

    test "ключ без doc:" do
      assert_compile_error(~r/^Options: f\/1: @opts_schema: ключи без doc: строкой: \[:size, \[:nested, :key\]\]$/, """
      @opts_schema [
        size: [type: :integer],
        nested: [type: :keyword_list, doc: "Вложенные.", keys: [key: [type: :atom]]]
      ]
      def f(opts), do: opts
      """)
    end

    test "умолчание не проходит схему" do
      assert_compile_error(~r/^Options: f\/1: @opts_schema: умолчание: invalid value for :size option/, """
      @opts_schema [size: [type: :pos_integer, default: 0, doc: "Размер."]]
      def f(opts), do: opts
      """)
    end

    test "атрибут над defp, defmacro, defmacrop" do
      for kind <- ~w(defp defmacro defmacrop) do
        assert_compile_error(~r/^Options: f\/1: @opts_schema стоит над #{kind}: схема опций — только у def$/, """
        @opts_schema [size: [type: :integer, doc: "Размер."]]
        #{kind} f(opts), do: opts
        def g(opts), do: opts
        """)
      end
    end

    test "атрибут над defdelegate" do
      assert_compile_error(~r/^Options: f\/1: @opts_schema стоит над def, раскрытым мимо Core.Options/, """
      @opts_schema [size: [type: :integer, doc: "Размер."]]
      defdelegate f(opts), to: Keyword, as: :keys
      """)
    end

    test "атрибут перед второй клаузой" do
      assert_compile_error(~r/^Options: f\/2: @opts_schema ставится перед первой клаузой функции$/, """
      def f(:a, opts), do: opts
      @opts_schema [size: [type: :integer, doc: "Размер."]]
      def f(:b, opts), do: opts
      """)
    end

    test "атрибут между головой без тела и первой клаузой" do
      assert_compile_error(~r/^Options: f\/2: @opts_schema ставится перед головой функции$/, """
      def f(subject, opts \\\\ [])
      @opts_schema [size: [type: :integer, doc: "Размер."]]
      def f(:a, opts), do: opts
      """)
    end

    test "висячий атрибут" do
      assert_compile_error(~r/^Options: @opts_schema: висячий атрибут: за ним нет def$/, """
      def f(opts), do: opts
      @opts_schema [size: [type: :integer, doc: "Размер."]]
      """)
    end

    test "паттерн на опциях" do
      assert_compile_error(~r/^Options: f\/1: опции — переменная, а не паттерн: \[size: size\]$/, """
      @opts_schema [size: [type: :integer, doc: "Размер."]]
      def f(size: size), do: size
      """)

      assert_compile_error(~r/^Options: f\/1: опции — переменная, а не паттерн: \[_ \| _\] = opts$/, """
      @opts_schema [size: [type: :integer, doc: "Размер."]]
      def f([_ | _] = opts), do: opts
      """)
    end

    test "guard на опциях кроме is_list/1" do
      assert_compile_error(~r/^Options: f\/1: на опциях допустим только guard is_list\/1$/, """
      @opts_schema [size: [type: :integer, doc: "Размер."]]
      def f(opts) when is_list(opts) and length(opts) > 0, do: opts
      """)

      assert_compile_error(~r/^Options: f\/1: на опциях допустим только guard is_list\/1$/, """
      @opts_schema [size: [type: :integer, doc: "Размер."]]
      def f(opts) when not is_list(opts), do: opts
      """)
    end

    test "схема, которую нельзя сохранить в коде" do
      assert_compile_error(~r/^Options: f\/1: @opts_schema: схема не сохраняется в коде: /, """
      @opts_schema [size: [type: {:fun, 0}, default: fn -> 1 end, doc: "Размер."]]
      def f(opts), do: opts
      """)
    end

    test "функция без аргументов" do
      assert_compile_error(~r/^Options: f\/0: у функции нет аргумента опций$/, """
      @opts_schema [size: [type: :integer, doc: "Размер."]]
      def f, do: :ok
      """)
    end
  end

  # ---

  # Строка, а не `quote`: `def` из `quote` теста раскрылся бы `Kernel.def` по импорту теста.
  defp assert_compile_error(message, body) do
    module = "Core.OptionsTest.Compiled#{System.unique_integer([:positive])}"

    assert_raise CompileError, message, fn ->
      Code.compile_string("""
      defmodule #{module} do
        use Core.Options

      #{body}
      end
      """)
    end
  end
end
