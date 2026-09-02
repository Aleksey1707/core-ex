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
    assert_raise CompileError, ~r/WithRequire: missing required option\(s\): \[:b\]/, fn ->
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
    assert_raise CompileError, ~r/WithValidate: unknown option\(s\): \[:foo\]/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Helper.OptsTest.ValidateUnknown do
            use Core.Helper.OptsTest.WithValidate, name: "X", foo: 1
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
    assert :ok == Opts.allowed!([:get, :insert], ~w(get insert)a, "method(s)", "T")

    assert_raise CompileError, ~r/T: unknown method\(s\): \[:foo\]/, fn ->
      Opts.allowed!([:get, :foo], ~w(get insert)a, "method(s)", "T")
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

    assert_raise CompileError, ~r/T: missing required option\(s\): \[:mod\]/, fn ->
      Opts.module!([], :mod, "T")
    end
  end

  test "binary! читает строковую опцию" do
    assert "roles" == Opts.binary!([topic: "roles"], :topic, "T")

    assert_raise CompileError, ~r/T: topic: ожидается строка, получено :roles/, fn ->
      Opts.binary!([topic: :roles], :topic, "T")
    end
  end
end
