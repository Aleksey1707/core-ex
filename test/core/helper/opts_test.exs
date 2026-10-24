defmodule Core.Helper.OptsTest do
  use ExUnit.Case, async: true

  alias Core.Helper.Opts

  defmodule WithRequire do
    @moduledoc false

    defmacro __using__(opts) do
      quote bind_quoted: [opts: opts] do
        Core.Helper.Opts.require!(opts, ~w(a b)a, "WithRequire")
        @opts opts
      end
    end
  end

  defmodule WithValidate do
    @moduledoc false

    defmacro __using__(opts) do
      quote bind_quoted: [opts: opts] do
        Core.Helper.Opts.validate!(opts, ~w(name)a, ~w(min_len max_len)a, "WithValidate")
        @opts opts
      end
    end
  end

  defmodule Exports do
    @moduledoc false

    def new(value), do: {:ok, value}
  end

  test "require! пропускает полный набор обязательных ключей" do
    Code.eval_quoted(
      quote do
        defmodule Core.Helper.OptsTest.RequireOk do
          use Core.Helper.OptsTest.WithRequire, a: 1, b: 2
        end
      end
    )
  end

  test "require! сообщает об отсутствующих ключах с label" do
    assert_raise CompileError, ~r/WithRequire: нет обязательных опций: \[:b\]/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Helper.OptsTest.RequireMissing do
            use Core.Helper.OptsTest.WithRequire, a: 1
          end
        end
      )
    end
  end

  test "validate! отклоняет неизвестные ключи с label" do
    assert_raise CompileError, ~r/^WithValidate: неизвестные опции: \[:foo\]$/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Helper.OptsTest.ValidateUnknown do
            use Core.Helper.OptsTest.WithValidate, name: "X", foo: 1
          end
        end
      )
    end
  end

  test "validate! сообщает о недостающих без неизвестных прежним текстом" do
    assert_raise CompileError, ~r/^WithValidate: нет обязательных опций: \[:name\]$/, fn ->
      Opts.validate!([min_len: 1], ~w(name)a, ~w(min_len)a, "WithValidate")
    end
  end

  test "validate! называет недостающие и неизвестные одной ошибкой" do
    assert_raise CompileError,
                 ~r/^WithValidate: нет обязательных опций: \[:name\]; неизвестные опции: \[:foo\]$/,
                 fn ->
                   Code.eval_quoted(
                     quote do
                       defmodule Core.Helper.OptsTest.ValidateBoth do
                         use Core.Helper.OptsTest.WithValidate, foo: 1
                       end
                     end
                   )
                 end
  end

  test "validate! отклоняет не-keyword" do
    assert_raise CompileError, ~r/T: ожидается keyword opts/, fn ->
      Opts.validate!([:a, :b], [], [], "T")
    end
  end

  test "allowed! проверяет подмножество" do
    assert :ok == Opts.allowed!([:get, :insert], ~w(get insert)a, "метод(ы)", "T")

    assert_raise CompileError, ~r/T: неизвестные метод\(ы\): \[:foo\]/, fn ->
      Opts.allowed!([:get, :foo], ~w(get insert)a, "метод(ы)", "T")
    end
  end

  test "module! читает опцию, проверяет экспорты и подставляет default" do
    assert Exports == Opts.module!([mod: Exports], :mod, "T", exports: [new: 1])
    assert Exports == Opts.module!([], :mod, "T", default: Exports)

    assert_raise CompileError, ~r/T: mod: модуль .* должен экспортировать fun\/2/, fn ->
      Opts.module!([mod: Exports], :mod, "T", exports: [fun: 2])
    end

    assert_raise CompileError, ~r/T: mod: ожидается модуль, получено "x"/, fn ->
      Opts.module!([mod: "x"], :mod, "T")
    end

    assert_raise CompileError, ~r/^T: mod: модуль Core\.Helper\.OptsTest\.Nope недоступен/, fn ->
      Opts.module!([mod: Core.Helper.OptsTest.Nope], :mod, "T")
    end

    assert_raise CompileError, ~r/T: нет обязательных опций: \[:mod\]/, fn ->
      Opts.module!([], :mod, "T")
    end
  end

  test "binary! читает строковую опцию" do
    assert "roles" == Opts.binary!([topic: "roles"], :topic, "T")

    assert_raise CompileError, ~r/T: topic: ожидается строка, получено :roles/, fn ->
      Opts.binary!([topic: :roles], :topic, "T")
    end
  end

  test "atom! читает опцию-атом" do
    assert :shadow_copy == Opts.atom!([key: :shadow_copy], :key, "T")

    assert_raise CompileError, ~r/T: key: ожидается атом, получено "shadow_copy"/, fn ->
      Opts.atom!([key: "shadow_copy"], :key, "T")
    end

    assert_raise CompileError, ~r/T: key: ожидается атом, получено nil/, fn ->
      Opts.atom!([key: nil], :key, "T")
    end
  end

  describe "expand!" do
    test "раскрывает сигилы ~w()a / ~D[] / ~U[] и алиасы" do
      opts =
        quote(do: [only: ~w(get save)a, on: ~D[2026-01-02], at: ~U[2026-01-02 03:04:05Z], mod: Opts])
        |> Opts.expand!(__ENV__, "T")
        |> Opts.literal!([], "T")

      assert opts == [only: [:get, :save], on: ~D[2026-01-02], at: ~U[2026-01-02 03:04:05Z], mod: Opts]
    end

    test "сворачивает унарный минус над числом в списках и парах" do
      opts = Opts.expand!(quote(do: [min: -1, range: [{:lo, -2.5}, {:hi, 3}]]), __ENV__, "T")

      assert opts == [min: -1, range: [lo: -2.5, hi: 3]]
    end

    test "список опций выражением — CompileError «ожидается литеральный keyword»" do
      assert_raise CompileError, ~r/^T: ожидается литеральный keyword, получено @opts$/, fn ->
        Opts.expand!(quote(do: @opts), __ENV__, "T")
      end
    end
  end

  describe "literal!" do
    test "вычисляет кортеж и struct, опцию-выражение отдаёт AST" do
      opts =
        quote(do: [pair: {:a, 1, [b: 2]}, at: %Date{year: 2026, month: 1, day: 2}, with: &Exports.new/1])
        |> Opts.expand!(__ENV__, "T")
        |> Opts.literal!(~w(with)a, "T")

      assert opts[:pair] == {:a, 1, [b: 2]}
      assert opts[:at] == %Date{year: 2026, month: 1, day: 2}
      assert Macro.to_string(opts[:with]) == "&Exports.new/1"
    end

    test "захват в опции-литерале — CompileError «ожидается литерал»" do
      assert_raise CompileError, ~r/^T: with: ожидается литерал, получено &Exports.new\/1$/, fn ->
        Opts.literal!([with: quote(do: &Exports.new/1)], [], "T")
      end
    end

    test "атрибут в опции-литерале — CompileError «ожидается литерал»" do
      assert_raise CompileError, ~r/^T: values: ожидается литерал, получено @values$/, fn ->
        Opts.literal!([values: quote(do: @values)], ~w(name)a, "T")
      end
    end
  end

  test "reject! — CompileError «<where>: <message>»" do
    assert_raise CompileError, ~r/^T: only: ожидается список, получено 1$/, fn ->
      Opts.reject!("T: only", "ожидается список, получено 1")
    end
  end

  test "binary_value! проверяет значение опции-выражения" do
    assert "Имя" == Opts.binary_value!("Имя", :name, "T")

    assert_raise CompileError, ~r/^T: name: ожидается строка, получено 1$/, fn ->
      Opts.binary_value!(1, :name, "T")
    end
  end
end
