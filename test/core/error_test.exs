defmodule Core.ErrorTest do
  use ExUnit.Case, async: true

  alias Core.Error
  require Error

  describe "domain/app" do
    test "кладёт произвольный detail и parent: nil по умолчанию" do
      err =
        Error.domain(__MODULE__,
          code: :bad,
          ns: :test,
          message: "плохо",
          detail: %{x: 1}
        )

      assert %Error{
               kind: :domain,
               ns: :test,
               code: :bad,
               detail: %{x: 1},
               parent: nil,
               message: "плохо"
             } = err

      assert to_string(err) == "плохо"
    end

    test "app без message → nil и fallback to_string" do
      err = Error.app(__MODULE__, code: :fail, ns: :test)

      assert %Error{kind: :app, message: nil, detail: nil, parent: nil} = err
      assert to_string(err) == "test/fail"
    end

    test "domain/1 и app/1 берут module из __CALLER__" do
      err =
        Error.domain(
          code: :bad,
          ns: :test,
          message: "плохо",
          detail: 1
        )

      assert %Error{module: __MODULE__, kind: :domain, code: :bad} = err

      app_err = Error.app(code: :fail, ns: :test)
      assert %Error{module: __MODULE__, kind: :app, code: :fail} = app_err
    end

    test "app принимает struct как detail" do
      assert %Error{detail: %URI{}} =
               Error.app(__MODULE__,
                 code: :fail,
                 ns: :test,
                 message: "fail",
                 detail: URI.parse("http://x")
               )
    end

    test "domain без обязательного attr в литерале → CompileError" do
      assert_raise CompileError, ~r/missing required option\(s\): \[:message\]/, fn ->
        compile_error_factory("code: :x, ns: :test")
      end

      assert_raise CompileError, ~r/missing required option\(s\): \[:code\]/, fn ->
        compile_error_factory("ns: :test, message: \"x\"")
      end
    end

    test "domain с unknown attr в литерале → CompileError" do
      assert_raise CompileError, ~r/unknown option\(s\): \[:extra\]/, fn ->
        compile_error_factory("code: :x, ns: :test, message: \"x\", extra: true")
      end
    end

    test "domain с динамическим attrs без обязательного → KeyError" do
      opts = [code: :x, ns: :test]

      assert_raise KeyError, fn ->
        Error.domain(__MODULE__, opts)
      end

      opts = [ns: :test, message: "x"]

      assert_raise KeyError, fn ->
        Error.__domain__(__MODULE__, opts)
      end
    end

    test "parent: в attrs" do
      inner =
        Error.domain(__MODULE__,
          code: :inner,
          ns: :test,
          message: "inner",
          detail: :a
        )

      outer =
        Error.app(__MODULE__,
          code: :outer,
          ns: :test,
          message: "outer",
          parent: inner
        )

      assert outer.parent == inner
    end

    test "parent: не-Error → ArgumentError" do
      assert_raise ArgumentError, ~r/parent must be %Error\{\}/, fn ->
        Error.domain(__MODULE__,
          code: :x,
          ns: :test,
          message: "x",
          parent: :nope
        )
      end
    end
  end

  describe "wrap / unwrap / root / chain" do
    test "цепочка глубины 3" do
      root =
        Error.domain(__MODULE__,
          code: :root,
          ns: :a,
          message: "root",
          detail: 1
        )

      mid =
        Error.wrap(
          Error.domain(__MODULE__,
            code: :mid,
            ns: :b,
            message: "mid",
            detail: 2
          ),
          root
        )

      outer =
        Error.wrap(
          Error.app(__MODULE__,
            code: :outer,
            ns: :c,
            message: "outer",
            detail: 3
          ),
          mid
        )

      assert Error.unwrap(outer) == mid
      assert Error.unwrap(root) == nil
      assert Error.root(outer) == root
      assert Error.chain(outer) == [outer, mid, root]
      assert Error.format_chain(outer) == "outer: mid: root"
      assert to_string(outer) == "outer"
    end

    test "format_chain с nil message использует fallback" do
      root = Error.app(__MODULE__, code: :inner, ns: :a)
      outer = Error.wrap(Error.app(__MODULE__, code: :outer, ns: :b, message: "outer"), root)

      assert Error.format_chain(outer) == "outer: a/inner"
    end

    test "wrap с не-Error → FunctionClauseError" do
      err = Error.domain(__MODULE__, code: :x, ns: :test, message: "x")
      # Process.get/1 → dynamic(); намеренный misuse без type warning
      Process.put({__MODULE__, :bad_parent}, :nope)
      bad = Process.get({__MODULE__, :bad_parent})

      assert_raise FunctionClauseError, fn ->
        Error.wrap(err, bad)
      end
    end
  end

  describe "has?/find" do
    setup do
      root = Error.domain(__MODULE__, code: :not_found, ns: :product, message: "нет")

      mid =
        Error.wrap(
          Error.domain(__MODULE__, code: :read_only, ns: :product_draft, message: "ro"),
          root
        )

      outer =
        Error.wrap(Error.app(__MODULE__, code: :cycle_failed, ns: :outbox, message: "cycle"), mid)

      %{outer: outer, mid: mid, root: root}
    end

    test "has? по keyword", %{outer: outer} do
      assert Error.has?(outer, code: :not_found)
      assert Error.has?(outer, ns: :product_draft, code: :read_only)
      refute Error.has?(outer, code: :missing)
      refute Error.has?(outer, ns: :product, code: :read_only)
    end

    test "find возвращает узел из середины", %{outer: outer, mid: mid} do
      assert Error.find(outer, &(&1.code == :read_only)) == mid
      assert Error.find(outer, &(&1.code == :nope)) == nil
    end
  end

  describe "Enumerable" do
    setup do
      root =
        Error.domain(__MODULE__,
          code: :root,
          ns: :a,
          message: "root",
          detail: 1
        )

      mid =
        Error.wrap(
          Error.domain(__MODULE__,
            code: :mid,
            ns: :b,
            message: "mid",
            detail: 2
          ),
          root
        )

      outer =
        Error.wrap(
          Error.app(__MODULE__,
            code: :outer,
            ns: :c,
            message: "outer",
            detail: 3
          ),
          mid
        )

      %{outer: outer, mid: mid, root: root}
    end

    test "обход цепочки outer → root", %{outer: outer, mid: mid, root: root} do
      assert Enum.to_list(outer) == [outer, mid, root]
      assert Enum.count(outer) == 3
      assert root in outer
      assert mid in outer
      assert Enum.find(outer, &(&1.code == :mid)) == mid
      assert Enum.map(outer, & &1.code) == [:outer, :mid, :root]
      assert Enum.slice(outer, 1, 2) == [mid, root]
    end

    test "одиночная ошибка без parent" do
      err = Error.domain(__MODULE__, code: :solo, ns: :test, message: "solo")
      assert Enum.to_list(err) == [err]
    end
  end

  defp compile_error_factory(attrs) do
    mod = Module.concat([__MODULE__, :"C#{System.unique_integer([:positive])}"])

    Code.compile_string("""
    defmodule #{inspect(mod)} do
      require Core.Error

      def go do
        Core.Error.domain(__MODULE__, #{attrs})
      end
    end
    """)
  end
end
