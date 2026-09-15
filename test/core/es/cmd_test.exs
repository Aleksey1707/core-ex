defmodule Core.Es.CmdTest do
  use ExUnit.Case, async: true

  describe "use Core.Es.Cmd" do
    test "by и at в @enforce_keys — команда с интроспекцией" do
      cmd =
        compile(
          Valid,
          quote(do: @enforce_keys(~w(name by at)a)),
          quote(do: defstruct(@enforce_keys))
        )

      assert cmd.__es_cmd__()
    end

    test "без by или at в @enforce_keys — CompileError" do
      for {name, keys} <- [{NoBy, ~w(name at)a}, {NoAt, ~w(name by)a}] do
        assert_raise CompileError, ~r/обязан объявить \[:by, :at\] в @enforce_keys/, fn ->
          compile(
            name,
            quote(do: @enforce_keys(unquote(keys))),
            quote(do: defstruct(~w(name by at)a))
          )
        end
      end
    end

    test "by и at в defstruct без @enforce_keys — CompileError" do
      assert_raise CompileError, ~r/обязан объявить \[:by, :at\] в @enforce_keys/, fn ->
        compile(NotEnforced, nil, quote(do: defstruct(~w(by at)a)))
      end
    end

    test "без defstruct — CompileError" do
      assert_raise CompileError, ~r/команда — struct: нет defstruct/, fn ->
        compile(NoStruct, nil, nil)
      end
    end

    test "отклоняет опции" do
      assert_raise CompileError, ~r/неизвестные опции: \[:aggregate\]/, fn ->
        Code.eval_quoted(
          quote do
            defmodule Core.Es.CmdTest.WithOpts do
              use Core.Es.Cmd, aggregate: Core.Version
            end
          end
        )
      end
    end
  end

  # ---

  defp compile(name, enforce, struct) do
    module = Module.concat(__MODULE__, name)

    Code.eval_quoted(
      quote do
        defmodule unquote(module) do
          use Core.Es.Cmd

          unquote(enforce)
          unquote(struct)
        end
      end
    )

    module
  end
end
