Code.require_file("../../scripts/credo_checks.exs", __DIR__)

defmodule CredoChecks.FunctionExportedTest do
  use Credo.Test.Case, async: true

  alias CredoChecks.FunctionExported

  setup_all do
    {:ok, _apps} = Application.ensure_all_started(:credo)
    :ok
  end

  test "function_exported?/3 — нарушение с заменой" do
    """
    defmodule A do
      def codec?(mod), do: function_exported?(mod, :__es_type__, 0)
    end
    """
    |> to_source_file()
    |> run_check(FunctionExported)
    |> assert_issue(fn issue ->
      assert issue.line_no == 2
      assert issue.trigger == "function_exported?"
      assert issue.message =~ "Core.Helper.Module.exports?/3"
    end)
  end

  test "Kernel.function_exported?/3 и :erlang.function_exported/3 — нарушения" do
    """
    defmodule A do
      def a?(mod), do: Kernel.function_exported?(mod, :a, 0)
      def b?(mod), do: :erlang.function_exported(mod, :b, 0)
    end
    """
    |> to_source_file()
    |> run_check(FunctionExported)
    |> assert_issues(fn issues -> assert Enum.map(issues, & &1.line_no) |> Enum.sort() == [2, 3] end)
  end

  test "захват &function_exported?/3 — нарушение" do
    """
    defmodule A do
      def codecs(mods), do: Enum.filter(mods, &function_exported?(&1, :__es_type__, 0))
    end
    """
    |> to_source_file()
    |> run_check(FunctionExported)
    |> assert_issue()
  end

  test "защищённый Code.ensure_loaded? вызов тоже нарушение: замена одна" do
    """
    defmodule A do
      def a?(mod), do: Code.ensure_loaded?(mod) and function_exported?(mod, :a, 0)
    end
    """
    |> to_source_file()
    |> run_check(FunctionExported)
    |> assert_issue()
  end

  test "хелпер и одноимённая функция другого модуля — без нарушений" do
    """
    defmodule A do
      alias Core.Helper

      def a?(mod), do: Helper.Module.exports?(mod, :a, 0)
      def b?(mod), do: Other.function_exported?(mod, :b, 0)
    end
    """
    |> to_source_file()
    |> run_check(FunctionExported)
    |> refute_issues()
  end
end
