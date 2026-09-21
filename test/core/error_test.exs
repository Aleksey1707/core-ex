defmodule Core.ErrorTest do
  use ExUnit.Case, async: true

  alias Core.Error
  alias Core.Exc
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

    test "пустой message → fallback ns/code" do
      err = Error.domain(__MODULE__, code: :bad, ns: :test, message: "")

      assert to_string(err) == "test/bad"
      assert Error.format_chain(err) == "test/bad"
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
      assert_raise CompileError, ~r/нет обязательных опций: \[:message\]/, fn ->
        compile_error_factory("code: :x, ns: :test")
      end

      assert_raise CompileError, ~r/нет обязательных опций: \[:code\]/, fn ->
        compile_error_factory("ns: :test, message: \"x\"")
      end
    end

    test "app и /1-формы тоже проверяются на compile-time" do
      assert_raise CompileError, ~r/нет обязательных опций: \[:ns\]/, fn ->
        compile_factory("Core.Error.app(__MODULE__, code: :x)")
      end

      assert_raise CompileError, ~r/неизвестные опции: \[:extra\]/, fn ->
        compile_factory("Core.Error.app(code: :x, ns: :test, extra: 1)")
      end

      assert_raise CompileError, ~r/нет обязательных опций: \[:message\]/, fn ->
        compile_factory("Core.Error.domain(code: :x, ns: :test)")
      end
    end

    test "domain с unknown attr в литерале → CompileError" do
      assert_raise CompileError, ~r/неизвестные опции: \[:extra\]/, fn ->
        compile_error_factory("code: :x, ns: :test, message: \"x\", extra: true")
      end
    end

    test "domain с дублирующимся attr в литерале → CompileError" do
      assert_raise CompileError, ~r/дублирующиеся опции: \[:code\]/, fn ->
        compile_error_factory("code: :x, ns: :test, message: \"x\", code: :y")
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

    test "domain с динамическим attrs и лишним ключом → ArgumentError" do
      opts = [code: :x, ns: :test, message: "x", typo: 1]

      assert_raise ArgumentError, ~r/неизвестные опции: \[:typo\]/, fn ->
        Error.domain(__MODULE__, opts)
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

    test "parent: не-Error → FunctionClauseError" do
      # Process.get/1 → dynamic(); намеренный misuse без type warning
      Process.put({__MODULE__, :bad_parent}, :nope)
      bad = Process.get({__MODULE__, :bad_parent})

      assert_raise FunctionClauseError, fn ->
        Error.domain(__MODULE__,
          code: :x,
          ns: :test,
          message: "x",
          parent: bad
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

    test "has? с пустым критерием → FunctionClauseError", %{outer: outer} do
      # Process.get/1 → dynamic(); намеренный misuse без type warning
      Process.put({__MODULE__, :empty_opts}, [])
      empty = Process.get({__MODULE__, :empty_opts})

      assert_raise FunctionClauseError, fn ->
        Error.has?(outer, empty)
      end
    end

    test "has? с неизвестным ключом → ArgumentError", %{outer: outer} do
      assert_raise ArgumentError, ~r/неизвестный ключ фильтра has\?: :nope/, fn ->
        Error.has?(outer, nope: 1)
      end
    end

    test "has? с не-keyword критерием → ArgumentError", %{outer: outer} do
      assert_raise ArgumentError, ~r/критерий has\? должен быть keyword-парой/, fn ->
        Error.has?(outer, [:ns])
      end
    end

    test "has? по kind и module", %{outer: outer, root: root} do
      assert Error.has?(outer, kind: :app)
      assert Error.has?(outer, kind: :domain)
      assert Error.has?(outer, module: __MODULE__)
      refute Error.has?(outer, module: Core.Error)
      assert Error.has?(root, kind: :domain, module: __MODULE__)
      refute Error.has?(root, kind: :app)
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

  describe "many" do
    setup do
      first = Error.domain(__MODULE__, code: :blank, ns: :form, message: "пусто")
      second = Error.domain(__MODULE__, code: :too_long, ns: :form, message: "длинно")

      %{first: first, second: second}
    end

    test "собирает контейнер из состава", %{first: first, second: second} do
      err =
        Error.many(__MODULE__,
          code: :invalid,
          ns: :form,
          message: "форма невалидна",
          errors: [first, second]
        )

      assert %Error{
               kind: :domain,
               ns: :form,
               code: :invalid,
               module: __MODULE__,
               message: "форма невалидна",
               detail: nil,
               parent: nil,
               errors: [^first, ^second]
             } = err
    end

    test "many/1 берёт module из __CALLER__", %{first: first} do
      assert %Error{module: __MODULE__, code: :invalid} =
               Error.many(code: :invalid, ns: :form, message: "форма", errors: [first])
    end

    test "обычная ошибка несёт пустой errors" do
      assert %Error{errors: []} = Error.domain(__MODULE__, code: :x, ns: :test, message: "x")
      assert %Error{errors: []} = Error.app(__MODULE__, code: :x, ns: :test)
    end

    test "kind выводится по слабейшему звену", %{first: first, second: second} do
      app = Error.app(__MODULE__, code: :timeout, ns: :infra, message: "таймаут")

      assert %Error{kind: :domain} = many([first, second])
      assert %Error{kind: :app} = many([first, app])
      assert %Error{kind: :app} = many([app, app])
    end

    test "kind опцией не принимается" do
      assert_raise CompileError, ~r/неизвестные опции: \[:kind\]/, fn ->
        compile_factory(~s|Core.Error.many(code: :x, ns: :t, message: "m", errors: [], kind: :app)|)
      end
    end

    test "errors обязателен в литерале" do
      assert_raise CompileError, ~r/нет обязательных опций: \[:errors\]/, fn ->
        compile_factory(~s|Core.Error.many(code: :x, ns: :t, message: "m")|)
      end

      assert_raise CompileError, ~r/нет обязательных опций: \[:message\]/, fn ->
        compile_factory(~s|Core.Error.many(__MODULE__, code: :x, ns: :t, errors: [])|)
      end

      assert_raise CompileError, ~r/дублирующиеся опции: \[:errors\]/, fn ->
        compile_factory(~s|Core.Error.many(code: :x, ns: :t, message: "m", errors: [], errors: [])|)
      end
    end

    test "динамический attrs без errors → KeyError" do
      opts = [code: :x, ns: :test, message: "x"]

      assert_raise KeyError, fn ->
        Error.many(__MODULE__, opts)
      end
    end

    test "пустой состав → ArgumentError" do
      assert_raise ArgumentError, ~r/множество ошибок не может быть пустым/, fn ->
        many([])
      end
    end

    test "элемент не %Error{} → ArgumentError", %{first: first} do
      assert_raise ArgumentError, ~r/элемент множества ошибок должен быть %Core.Error\{\}/, fn ->
        many([first, :nope])
      end
    end

    test "элемент с непустым errors → ArgumentError", %{first: first, second: second} do
      nested = many([first])

      assert_raise ArgumentError, ~r/множество ошибок плоское/, fn ->
        many([second, nested])
      end
    end

    test "порядок входа сохраняется, дубли не схлопываются", %{first: first} do
      same = Error.domain(__MODULE__, code: :blank, ns: :form, message: "пусто ещё раз")
      other = Error.domain(__MODULE__, code: :bad, ns: :form, message: "плохо")

      assert %Error{errors: [^other, ^first, ^same]} = many([other, first, same])
    end

    test "множество из одного элемента", %{first: first} do
      assert %Error{errors: [^first], kind: :domain} = many([first])
    end

    test "parent у контейнера независим от состава", %{first: first, second: second} do
      cause = Error.app(__MODULE__, code: :db, ns: :infra, message: "база")

      err =
        Error.many(__MODULE__,
          code: :invalid,
          ns: :form,
          message: "форма невалидна",
          errors: [first, second],
          parent: cause
        )

      assert %Error{parent: ^cause, errors: [^first, ^second]} = err
      assert Error.chain(err) == [err, cause]
      assert Error.root(err) == cause
    end

    test "контейнер можно обернуть причиной", %{first: first} do
      container = many([first])
      cause = Error.app(__MODULE__, code: :db, ns: :infra, message: "база")

      assert %Error{errors: [^first], parent: ^cause} = Error.wrap(container, cause)
    end
  end

  describe "контейнер не бывает причиной" do
    setup do
      element = Error.domain(__MODULE__, code: :blank, ns: :form, message: "пусто")

      %{container: many([element])}
    end

    test "wrap вторым аргументом", %{container: container} do
      err = Error.domain(__MODULE__, code: :x, ns: :test, message: "x")

      assert_raise ArgumentError, ~r/множество ошибок не может быть причиной/, fn ->
        Error.wrap(err, container)
      end
    end

    test "parent: у domain", %{container: container} do
      assert_raise ArgumentError, ~r/множество ошибок не может быть причиной/, fn ->
        Error.domain(__MODULE__, code: :x, ns: :test, message: "x", parent: container)
      end
    end

    test "parent: у app", %{container: container} do
      assert_raise ArgumentError, ~r/множество ошибок не может быть причиной/, fn ->
        Error.app(__MODULE__, code: :x, ns: :test, parent: container)
      end
    end

    test "parent: у many", %{container: container} do
      element = Error.domain(__MODULE__, code: :bad, ns: :form, message: "плохо")

      assert_raise ArgumentError, ~r/множество ошибок не может быть причиной/, fn ->
        Error.many(__MODULE__,
          code: :invalid,
          ns: :form,
          message: "форма",
          errors: [element],
          parent: container
        )
      end
    end
  end

  describe "format_chain с составом" do
    setup do
      first = Error.domain(__MODULE__, code: :blank, ns: :form, message: "пусто")
      second = Error.domain(__MODULE__, code: :too_long, ns: :form, message: "длинно")

      %{first: first, second: second}
    end

    test "контейнер печатается вместе с составом", %{first: first, second: second} do
      assert Error.format_chain(many([first, second])) == "множество (пусто | длинно)"
    end

    test "контейнер с причиной", %{first: first, second: second} do
      cause = Error.app(__MODULE__, code: :db, ns: :infra, message: "база")

      assert Error.format_chain(Error.wrap(many([first, second]), cause)) ==
               "множество (пусто | длинно): база"
    end

    test "цепочка элемента печатается рекурсивно", %{first: first, second: second} do
      cause = Error.app(__MODULE__, code: :db, ns: :infra, message: "база")

      assert Error.format_chain(many([Error.wrap(first, cause), second])) ==
               "множество (пусто: база | длинно)"
    end

    test "элемент без message — fallback ns/code" do
      assert Error.format_chain(many([Error.app(__MODULE__, code: :timeout, ns: :infra)])) ==
               "множество (infra/timeout)"
    end

    test "множество из одного элемента", %{first: first} do
      assert Error.format_chain(many([first])) == "множество (пусто)"
    end

    test "у ошибки с пустым errors вывод прежний", %{first: first} do
      cause = Error.app(__MODULE__, code: :db, ns: :infra, message: "база")

      assert Error.format_chain(first) == "пусто"
      assert Error.format_chain(Error.wrap(first, cause)) == "пусто: база"
    end
  end

  describe "messages/1" do
    test "контейнер — тексты элементов в порядке состава" do
      first = Error.domain(__MODULE__, code: :blank, ns: :form, message: "пусто")
      second = Error.domain(__MODULE__, code: :too_long, ns: :form, message: "длинно")

      assert Error.messages(many([first, second])) == ["пусто", "длинно"]
    end

    test "контейнер — только состав, без outer и причины" do
      element = Error.domain(__MODULE__, code: :blank, ns: :form, message: "пусто")
      cause = Error.app(__MODULE__, code: :db, ns: :infra, message: "база")

      assert Error.messages(Error.wrap(many([element]), cause)) == ["пусто"]
    end

    test "обычная ошибка — один текст, цепочка не читается" do
      cause = Error.app(__MODULE__, code: :db, ns: :infra, message: "база")
      err = Error.wrap(Error.domain(__MODULE__, code: :bad, ns: :form, message: "плохо"), cause)

      assert Error.messages(err) == ["плохо"]
    end

    test "ошибка без message — fallback ns/code" do
      assert Error.messages(Error.app(__MODULE__, code: :timeout, ns: :infra)) ==
               ["infra/timeout"]
    end

    test "элемент без message — fallback ns/code" do
      element = Error.app(__MODULE__, code: :timeout, ns: :infra)
      other = Error.domain(__MODULE__, code: :blank, ns: :form, message: "пусто")

      assert Error.messages(many([element, other])) == ["infra/timeout", "пусто"]
    end
  end

  describe "Exc" do
    test "контейнер — format_chain с составом" do
      first = Error.domain(__MODULE__, code: :blank, ns: :form, message: "пусто")
      second = Error.domain(__MODULE__, code: :too_long, ns: :form, message: "длинно")

      assert Exception.message(Exc.exception(many([first, second]))) ==
               "множество (пусто | длинно)"
    end

    test "обычная ошибка — свой текст без цепочки" do
      cause = Error.app(__MODULE__, code: :db, ns: :infra, message: "база")
      err = Error.wrap(Error.domain(__MODULE__, code: :bad, ns: :form, message: "плохо"), cause)

      assert Exception.message(Exc.exception(err)) == "плохо"
    end
  end

  describe "обход не касается состава" do
    setup do
      element = Error.domain(__MODULE__, code: :blank, ns: :form, message: "пусто")
      cause = Error.app(__MODULE__, code: :db, ns: :infra, message: "база")

      %{container: Error.wrap(many([element]), cause), element: element, cause: cause}
    end

    test "has? по коду элемента — false", %{container: container} do
      refute Error.has?(container, code: :blank)
      refute Error.has?(container, ns: :form, code: :blank)
      assert Error.has?(container, code: :db)
      assert Error.has?(container, code: :invalid)
    end

    test "find не видит элемент", %{container: container} do
      assert Error.find(container, &(&1.code == :blank)) == nil
      assert %Error{code: :db} = Error.find(container, &(&1.code == :db))
    end

    test "chain, root и Enumerable читают цепочку причин", %{
      container: container,
      element: element,
      cause: cause
    } do
      assert Error.chain(container) == [container, cause]
      assert Error.root(container) == cause
      assert Error.unwrap(container) == cause
      assert Enum.count(container) == 2
      refute element in Enum.to_list(container)
    end
  end

  defp many(errors) do
    Error.many(__MODULE__, code: :invalid, ns: :form, message: "множество", errors: errors)
  end

  defp compile_error_factory(attrs) do
    compile_factory("Core.Error.domain(__MODULE__, #{attrs})")
  end

  defp compile_factory(call) do
    mod = Module.concat([__MODULE__, :"C#{System.unique_integer([:positive])}"])

    Code.compile_string("""
    defmodule #{inspect(mod)} do
      require Core.Error

      def go do
        #{call}
      end
    end
    """)
  end
end
