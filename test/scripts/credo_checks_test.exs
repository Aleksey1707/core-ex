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

defmodule CredoChecks.OptsSchemaTest do
  use Credo.Test.Case, async: true

  alias CredoChecks.OptsSchema

  setup_all do
    {:ok, _apps} = Application.ensure_all_started(:credo)
    :ok
  end

  test "Keyword.get(opts, …) в публичной функции без схемы — нарушение" do
    """
    defmodule A do
      def run(source, opts \\\\ []) do
        size = Keyword.get(opts, :batch_size, 100)
        {source, size}
      end
    end
    """
    |> to_source_file()
    |> run_check(OptsSchema)
    |> assert_issue(fn issue ->
      assert issue.line_no == 3
      assert issue.trigger == "opts"
      assert issue.message =~ "@opts_schema"
    end)
  end

  test "схема над первой клаузой снимает нарушение со всех клауз функции, но не с соседней" do
    """
    defmodule A do
      use Core.Options

      @opts_schema [size: [type: :pos_integer, default: 1, doc: "Размер."]]
      @spec run(term(), keyword()) :: term()

      def run(source, opts \\\\ [])
      def run(nil, opts), do: Keyword.fetch!(opts, :size)
      def run(source, opts), do: {source, Keyword.fetch!(opts, :size)}

      def other(opts), do: Keyword.fetch!(opts, :size)
    end
    """
    |> to_source_file()
    |> run_check(OptsSchema)
    |> assert_issue(fn issue -> assert issue.line_no == 11 end)
  end

  test "opts[:…], Keyword.fetch/2 и Keyword.validate!/2 — нарушения" do
    """
    defmodule A do
      def a(opts), do: opts[:size]
      def b(opts), do: Keyword.fetch(opts, :size)
      def c(opts), do: Keyword.validate!(opts, size: 1)
    end
    """
    |> to_source_file()
    |> run_check(OptsSchema)
    |> assert_issues(fn issues -> assert Enum.map(issues, & &1.line_no) == [2, 3, 4] end)
  end

  test "обратный вызов с @impl, defp и defmacro — без нарушений" do
    """
    defmodule A do
      @behaviour Plug

      @impl true
      def init(opts), do: Keyword.get(opts, :path)

      @impl Plug
      def call(conn, opts), do: {conn, opts[:path]}

      defp size(opts), do: Keyword.fetch!(opts, :size)
      defmacro build(opts), do: Keyword.get(opts, :name)
    end
    """
    |> to_source_file()
    |> run_check(OptsSchema)
    |> refute_issues()
  end

  test "@impl false обратного вызова не делает — нарушение" do
    """
    defmodule A do
      @impl false
      def init(opts), do: Keyword.get(opts, :path)
    end
    """
    |> to_source_file()
    |> run_check(OptsSchema)
    |> assert_issue(fn issue -> assert issue.line_no == 3 end)
  end

  test "опции целиком уходят дальше — вызовом, в спецификации ребёнка, после правки — без нарушений" do
    """
    defmodule A do
      def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))

      def child_spec(opts) do
        %{id: Keyword.get(opts, :name) || __MODULE__, start: {__MODULE__, :start_link, [opts]}}
      end

      def run(source, opts) do
        if Keyword.get(opts, :dry?), do: :ok, else: opts |> Keyword.delete(:dry?) |> Other.run(source)
      end
    end
    """
    |> to_source_file()
    |> run_check(OptsSchema)
    |> refute_issues()
  end

  test "правка опций без передачи дальше и Keyword.validate! при передаче — нарушения" do
    """
    defmodule A do
      def run(opts) do
        merged = Keyword.merge([size: 1], opts)
        {merged, Keyword.get(opts, :size)}
      end

      def other(opts) do
        opts = Keyword.validate!(opts, size: 1)
        Other.run(opts)
      end
    end
    """
    |> to_source_file()
    |> run_check(OptsSchema)
    |> assert_issues(fn issues -> assert Enum.map(issues, & &1.line_no) == [4, 8] end)
  end

  test "def внутри quote — генерируемый код, схема там MUST NOT — без нарушений" do
    """
    defmodule A do
      def build(name, opts) do
        quote do
          def unquote(name)(opts), do: Keyword.get(opts, :size)
          @opts unquote(opts)
        end
      end

      quote do
        def run(opts), do: opts[:size]
      end
    end
    """
    |> to_source_file()
    |> run_check(OptsSchema)
    |> refute_issues()
  end

  test "опции в приватный хелпер модуля не уходят дальше: его чтение — чтение функции" do
    """
    defmodule A do
      def run(source, opts), do: {source, size(opts)}
      def other(opts), do: Other.run(limit(opts))

      defp size(options), do: options |> Keyword.get(:size) |> bounded(options)
      defp bounded(size, options), do: min(size, Keyword.fetch!(options, :max))
      defp limit(opts), do: opts
    end
    """
    |> to_source_file()
    |> run_check(OptsSchema)
    |> assert_issue(fn issue -> assert {issue.line_no, issue.column} == {2, 44} end)
  end

  test "модуль разбора опций как данных — без нарушений, его соседи и вложенные — проверяются" do
    """
    defmodule Core.Prim.Opts do
      def boolean!(opts, keys), do: Enum.map(keys, &Keyword.get(opts, &1))

      defmodule Inner do
        def run(opts), do: opts[:size]
      end
    end

    defmodule Core.Codec.Plugin do
      defmodule Opts do
        def fields!(opts), do: Keyword.fetch!(opts, :fields)
      end

      def run(opts), do: opts[:size]
    end
    """
    |> to_source_file()
    |> run_check(OptsSchema)
    |> assert_issues(fn issues -> assert Enum.map(issues, & &1.line_no) == [5, 14] end)
  end
end

defmodule CredoChecks.UseOptsPerLineTest do
  use Credo.Test.Case,
    async: true

  alias CredoChecks.UseOptsPerLine

  setup_all do
    {:ok, _apps} = Application.ensure_all_started(:credo)
    :ok
  end

  test "две опции в строке use — нарушение" do
    """
    defmodule A do
      use Core.Enum, name: "Статус", values: ~w(new done)a
    end
    """
    |> to_source_file()
    |> run_check(UseOptsPerLine)
    |> assert_issue(fn issue ->
      assert issue.line_no == 2
      assert issue.trigger == "use"
      assert issue.message =~ "отдельной строке"
    end)
  end

  test "опции на строках после use, но две в одной строке или первая в строке use — нарушения" do
    """
    defmodule A do
      use Core.Enum,
        name: "Статус", values: ~w(new done)a

      use Core.Struct, name: "Заказ",
        fields: [id: [type: :integer], total: [type: :integer]]

      use Core.Codec, [name: "Кодек", plugins: []]
    end
    """
    |> to_source_file()
    |> run_check(UseOptsPerLine)
    |> assert_issues(fn issues -> assert Enum.map(issues, & &1.line_no) == [2, 5, 8] end)
  end

  test "одна опция в строке use, опции построчно и use без опций — без нарушений" do
    """
    defmodule A do
      use ExUnit.Case, async: true
      use GenServer
      use Core.Struct, fields: [id: [type: :integer], total: [type: :integer]]

      use Core.Enum,
        name: "Статус",
        values: ~w(new done)a

      quote do
        use Core.Codec,
          name: unquote(name),
          plugins: []
      end
    end
    """
    |> to_source_file()
    |> run_check(UseOptsPerLine)
    |> refute_issues()
  end
end

defmodule CredoChecks.EnumValuesTableTest do
  use Credo.Test.Case,
    async: true

  alias CredoChecks.EnumValuesTable

  setup_all do
    {:ok, _apps} = Application.ensure_all_started(:credo)
    :ok
  end

  test "значение без строки таблицы — нарушение с перечнем значений" do
    ~S'''
    defmodule Status do
      @moduledoc """
      Статус

      | Значение | Описание |
      |---|---|
      | `:new` | создан |
      """

      use Core.Enum,
        name: first_line(@moduledoc),
        values: ~w(new done failed)a
    end
    '''
    |> to_source_file()
    |> run_check(EnumValuesTable)
    |> assert_issue(fn issue ->
      assert issue.line_no == 10
      assert issue.message =~ "`:done`, `:failed`"
    end)
  end

  test "без таблицы, @moduledoc false, ячейка не в форме inspect и codes: — нарушения" do
    ~S'''
    defmodule NoTable do
      @moduledoc "Статус"

      use Core.Enum,
        name: "Статус",
        values: [:new]
    end

    defmodule Hidden do
      @moduledoc false

      use Core.Enum,
        name: "Статус",
        values: ~w(new)a
    end

    defmodule BareCell do
      @moduledoc """
      Статус

      | Значение | Описание |
      |---|---|
      | new | создан |
      """

      use Core.Enum,
        name: "Статус",
        values: ~w(new)a
    end

    defmodule Kind do
      @moduledoc """
      Вид

      | Значение | Код | Описание |
      |---|---|---|
      | `:human` | 1 | человек |
      """

      use Core.Enum,
        name: "Вид",
        codes: %{human: 1, car: 2}
    end
    '''
    |> to_source_file()
    |> run_check(EnumValuesTable)
    |> assert_issues(fn issues ->
      assert Enum.map(issues, &{&1.line_no, &1.message =~ "`:new`" or &1.message =~ "`:car`"}) ==
               [{4, true}, {12, true}, {26, true}, {40, true}]
    end)
  end

  test "каждое значение в таблице, значения не литералом и use другого модуля — без нарушений" do
    ~S'''
    defmodule Status do
      @moduledoc """
      Статус

      Описание выше таблицы.

      | Значение | Описание |
      |---|---|
      | `:new` | создан |
      | `:done` | выполнен |
      """

      use Core.Enum,
        name: first_line(@moduledoc),
        values: ~w(new done)a

      defmodule Nested do
        @moduledoc "Вложенный модуль без enum"
      end
    end

    defmodule Derived do
      @moduledoc "Статус"

      use Core.Enum,
        name: "Статус",
        values: @values
    end

    defmodule Other do
      @moduledoc "Не enum"

      use Core.Struct,
        name: "Структура",
        values: ~w(a b)a
    end
    '''
    |> to_source_file()
    |> run_check(EnumValuesTable)
    |> refute_issues()
  end
end
