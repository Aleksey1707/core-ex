defmodule SpecLintTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  @script Path.expand("../../scripts/spec_lint.exs", __DIR__)

  test "чистое дерево — код 0", %{tmp_dir: dir} do
    write(dir, "lib/a.ex", """
    defmodule A do
      @spec get(term()) :: Result.t(integer())
      @spec put(term()) :: Core.Result.unit()
      @callback run(term()) :: Result.t(integer(), :none)
    end
    """)

    assert {out, 0} = lint(dir)
    assert out =~ "нарушений нет"
  end

  test "valued прописью в `@spec` — нарушение с заменой", %{tmp_dir: dir} do
    write(dir, "lib/a.ex", """
    defmodule A do
      @spec get(term()) ::
              {:ok, integer()} | {:error, Error.t()}
    end
    """)

    assert {out, 1} = lint(dir)
    assert out =~ "lib/a.ex:2: "
    assert out =~ "`Result.t(integer())`"
    assert out =~ "правила — docs/rules/20-agreements.md"
  end

  test "unit прописью в `@callback`, причина не `Error.t()`", %{tmp_dir: dir} do
    write(dir, "lib/a.ex", """
    defmodule A do
      @callback put(term()) :: :ok | {:error, {atom(), String.t()}}
    end
    """)

    assert {out, 1} = lint(dir)
    assert out =~ "`Result.unit({atom(), String.t()})`"
  end

  test "`@type` и тип колбэка внутри него", %{tmp_dir: dir} do
    write(dir, "lib/a.ex", """
    defmodule A do
      @type to_message :: (term() -> {:ok, binary()} | {:error, Core.Error.t()})
    end
    """)

    assert {out, 1} = lint(dir)
    assert out =~ "`Result.t(binary())`"
  end

  test "спека внутри `quote` — тоже, с полным путём в подсказке", %{tmp_dir: dir} do
    write(dir, "lib/a.ex", """
    defmodule A do
      defmacro __using__(_opts) do
        quote do
          @spec all() :: {:ok, [unquote(item)]} | {:error, Core.Error.t()}
        end
      end
    end
    """)

    assert {out, 1} = lint(dir)
    assert out =~ "lib/a.ex:4: "
    assert out =~ "`Core.Result.t([unquote(item)])`"
  end

  test "несколько причин — объединение в параметре", %{tmp_dir: dir} do
    write(dir, "lib/a.ex", """
    defmodule A do
      @spec get() :: {:ok, term()} | {:error, :a} | {:error, :b}
    end
    """)

    assert {out, 1} = lint(dir)
    assert out =~ "`Result.t(term(), :a | :b)`"
  end

  test "избыточный параметр — кратчайшая форма", %{tmp_dir: dir} do
    write(dir, "lib/a.ex", """
    defmodule A do
      @spec a() :: Result.t(integer(), Error.t())
      @spec b() :: Core.Result.t(term())
      @spec c() :: Result.unit(Core.Error.t())
      @spec d() :: Result.t(term(), Error.t())
    end
    """)

    assert {out, 1} = lint(dir)
    assert out =~ "lib/a.ex:2: форма длиннее нужной — `Result.t(integer())`"
    assert out =~ "lib/a.ex:3: форма длиннее нужной — `Core.Result.t()`"
    assert out =~ "lib/a.ex:4: форма длиннее нужной — `Result.unit()`"
    assert out =~ "lib/a.ex:5: форма длиннее нужной — `Result.t()`"
  end

  test "несколько успехов — объединение значений, `any()` — как `term()`", %{tmp_dir: dir} do
    write(dir, "lib/a.ex", """
    defmodule A do
      @spec a() :: {:ok, integer()} | {:ok, atom()} | {:error, Error.t()}
      @spec b() :: {:ok, any()} | {:error, Error.t()}
    end
    """)

    assert {out, 1} = lint(dir)
    assert out =~ "lib/a.ex:2: результат прописью — `Result.t(integer() | atom())`"
    assert out =~ "lib/a.ex:3: результат прописью — `Result.t()`"
  end

  test "короткое `Result` внутри `quote` — нарушение", %{tmp_dir: dir} do
    write(dir, "lib/a.ex", """
    defmodule A do
      defmacro __using__(_opts) do
        quote do
          @spec get() :: Result.t(integer())
        end
      end
    end
    """)

    assert {out, 1} = lint(dir)
    assert out =~ "lib/a.ex:4: в `quote` — полный путь `Core.Result.t(integer())`"
  end

  test "`Result` под алиасом другого модуля — не `Core.Result`", %{tmp_dir: dir} do
    write(dir, "lib/a.ex", """
    defmodule A do
      alias Core.Pagination.Result

      @spec page() :: Result.t(term())
    end
    """)

    assert {_out, 0} = lint(dir)
  end

  test "исключения: третий вариант, unit с valued, один вариант, тапл длиннее пары", %{tmp_dir: dir} do
    write(dir, "lib/a.ex", """
    defmodule A do
      @type handler_result :: :ok | {:skip, term()} | {:error, term()}
      @type result :: :ok | {:ok, term()} | {:error, term()}
      @spec error(a) :: {:error, a} when a: var
      @callback put_many([term()]) :: :ok | {:error, non_neg_integer(), Error.t()}
      @spec other() :: Pagination.Result.t(integer())
    end
    """)

    assert {_out, 0} = lint(dir)
  end

  test "`Core.Result` задаёт имена сам — не проверяется", %{tmp_dir: dir} do
    write(dir, "lib/core/result.ex", """
    defmodule Core.Result do
      @type t(a, e) :: {:ok, a} | {:error, e}
      @type unit(e) :: :ok | {:error, e}
    end
    """)

    assert {_out, 0} = lint(dir)
  end

  test "`test/support` проверяется, остальной `test` — нет", %{tmp_dir: dir} do
    write(dir, "test/support/s.ex", "defmodule S do\n  @spec f() :: :ok | {:error, term()}\nend\n")
    write(dir, "test/a_test.exs", "defmodule ATest do\n  @spec f() :: :ok | {:error, term()}\nend\n")

    assert {out, 1} = lint(dir)
    assert out =~ "test/support/s.ex:2: "
    refute out =~ "a_test.exs"
  end

  test "у потребителя — путь правил `deps/core/…`", %{tmp_dir: dir} do
    write(dir, "deps/core/docs/rules/20-agreements.md", "")
    write(dir, "lib/a.ex", "defmodule A do\n  @spec f() :: :ok | {:error, term()}\nend\n")

    assert {out, 1} = lint(dir)
    assert out =~ "правила — deps/core/docs/rules/20-agreements.md"
  end

  defp write(dir, path, source) do
    path = Path.join(dir, path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, source)
  end

  defp lint(dir), do: System.cmd("elixir", [@script], cd: dir, env: bare_env(), stderr_to_stdout: true)

  defp bare_env do
    for {name, _value} <- System.get_env(), name not in ~w(PATH HOME LANG LC_ALL LC_CTYPE), into: %{}, do: {name, nil}
  end
end
