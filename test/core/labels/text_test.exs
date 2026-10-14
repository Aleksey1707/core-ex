defmodule Core.Labels.TextTest do
  use ExUnit.Case, async: true

  alias Core.Labels.Text
  alias Core.LabelsFixture.Name
  alias Core.LabelsFixture.Texts
  alias Core.LabelsFixture.Unit

  test "find/1 — функция текста Prim" do
    assert Text.find(Unit) == (&Texts.unit/1)
  end

  test "find/1 — nil у Prim без объявления и у модуля без Prim" do
    assert Text.find(Name) == nil
    assert Text.find(URI) == nil
  end

  describe "отказ сборки" do
    test "with: не захват — CompileError" do
      assert_raise CompileError, ~r/NotCapture: with: захват функции арности 1/, fn ->
        compile_text(:NotCapture, with: "Текст")
      end
    end

    test "захват другой арности — CompileError" do
      assert_raise CompileError, ~r/Arity: with: захват функции арности 1/, fn ->
        compile_text(:Arity, with: &Kernel.max/2)
      end
    end

    test "без with: — CompileError" do
      assert_raise CompileError, ~r/Labels.Text: нет обязательных опций: \[:with\]/, fn ->
        compile_text(:NoWith, [])
      end
    end

    test "модуль без use Core.Prim — CompileError" do
      assert_raise CompileError, ~r/NotPrim: не Prim: `use Core.Labels.Text` подключается после/, fn ->
        Code.eval_quoted(
          quote do
            defmodule Core.Labels.TextTest.NotPrim do
              use Core.Labels.Text, with: &Kernel.inspect/1
            end
          end
        )
      end
    end

    test "вместе с Core.Labels.ID — CompileError" do
      assert_raise CompileError, ~r/WithID: `use Core.Labels.ID` и `use Core.Labels.Text` вместе/, fn ->
        Code.eval_quoted(
          quote do
            defmodule Core.Labels.TextTest.WithID do
              use Core.Prim.UUID, name: "Id", version: 7

              use Core.Labels.ID, kind: :id

              use Core.Labels.Text, with: &Kernel.inspect/1
            end
          end
        )
      end
    end
  end

  # ---

  defp compile_text(name, opts) do
    module = Module.concat(__MODULE__, name)

    Code.eval_quoted(
      quote do
        defmodule unquote(module) do
          use Core.Prim.String, name: "Код", min_len: 1, max_len: 10

          use Core.Labels.Text, unquote(opts)
        end
      end
    )
  end
end
