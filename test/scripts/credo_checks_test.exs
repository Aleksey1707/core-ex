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

defmodule CredoChecks.UseOptsTest do
  use Credo.Test.Case, async: true

  alias Credo.Check.ConfigComment
  alias Credo.Check.ConfigCommentFinder
  alias CredoChecks.UseOpts

  setup_all do
    {:ok, _apps} = Application.ensure_all_started(:credo)
    :ok
  end

  test "bind_quoted в defp модуля с __using__ — нарушение" do
    """
    defmodule B do
      defmacro __using__(_opts), do: body([])

      defp body(opts) do
        quote bind_quoted: [opts: opts] do
          @opts opts
        end
      end
    end
    """
    |> to_source_file()
    |> run_check(UseOpts)
    |> assert_issue(fn issue ->
      assert issue.line_no == 5
      assert issue.message =~ "bind_quoted"
    end)
  end

  test "bind_quoted в модуле без __using__ — без нарушений" do
    """
    defmodule M do
      defmacro build(opts) do
        quote bind_quoted: [opts: opts], do: @opts(opts)
      end
    end
    """
    |> to_source_file()
    |> run_check(UseOpts)
    |> refute_issues()
  end

  test "пролог мимо expand! — нарушение на первом употреблении opts" do
    """
    defmodule B do
      alias Core.Helper

      defmacro __using__(opts) do
        Helper.Opts.validate!(opts, [], [], "B")
        quote(do: :ok)
      end
    end
    """
    |> to_source_file()
    |> run_check(UseOpts)
    |> assert_issue(fn issue ->
      assert issue.line_no == 5
      assert issue.message =~ "Core.Helper.Opts.expand!/3"
    end)
  end

  test "пролог через expand! или Prim.Opts.prepare! — без нарушений" do
    """
    defmodule A do
      alias Core.Helper

      defmacro __using__(opts) do
        opts = Helper.Opts.expand!(opts, __CALLER__, "A")
        Helper.Opts.validate!(opts, [], [], "A")
        quote(do: unquote(opts))
      end
    end

    defmodule B do
      defmacro __using__(opts) do
        opts |> Core.Helper.Opts.expand!(__CALLER__, "B") |> body()
      end
    end

    defmodule C do
      alias Core.Prim

      defmacro __using__(opts), do: Prim.Opts.prepare!(opts, C)
    end
    """
    |> to_source_file()
    |> run_check(UseOpts)
    |> refute_issues()
  end

  test "opts со значением по умолчанию проверяется как opts" do
    """
    defmodule B do
      defmacro __using__(opts \\\\ []) do
        quote(do: unquote(opts))
      end
    end
    """
    |> to_source_file()
    |> run_check(UseOpts)
    |> assert_issue(fn issue -> assert issue.line_no == 3 end)
  end

  test "guard __using__ над opts — употребление до пролога" do
    """
    defmodule B do
      defmacro __using__(opts) when is_list(opts) do
        opts |> Core.Helper.Opts.expand!(__CALLER__, "B") |> body()
      end
    end
    """
    |> to_source_file()
    |> run_check(UseOpts)
    |> assert_issue(fn issue -> assert issue.line_no == 2 end)
  end

  test "_opts — без нарушений" do
    """
    defmodule B do
      defmacro __using__(_opts), do: quote(do: :ok)
    end
    """
    |> to_source_file()
    |> run_check(UseOpts)
    |> refute_issues()
  end

  test "функции ключей — нарушение вне Prim.Wrapper" do
    source = """
    defmodule B do
      def required_keys, do: []
      def optional_keys(), do: []
      def expression_keys, do: []
    end
    """

    source
    |> to_source_file()
    |> run_check(UseOpts)
    |> assert_issues(fn issues -> assert Enum.map(issues, & &1.line_no) |> Enum.sort() == [2, 3, 4] end)

    source
    |> to_source_file("lib/core/prim/wrapper.ex")
    |> run_check(UseOpts)
    |> refute_issues()
  end

  test "credo:disable-for-next-line снимает нарушение пролога" do
    source_file =
      to_source_file("""
      defmodule B do
        defmacro __using__(opts) do
          # credo:disable-for-next-line CredoChecks.UseOpts
          Helper.Opts.require!(opts, [:a], "B")
          quote(do: use(Other, unquote(opts)))
        end
      end
      """)

    {_file, comments} = ConfigCommentFinder.find_and_set_in_source_file(source_file)

    issues =
      source_file
      |> run_check(UseOpts)
      |> assert_issue()
      |> List.wrap()

    assert Enum.reject(issues, fn issue -> Enum.any?(comments, &ConfigComment.ignores_issue?(&1, issue)) end) == []
  end
end
