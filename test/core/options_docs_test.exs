defmodule Core.OptionsDocsTest do
  # async: false — фикстуры собираются с глобальной опцией компилятора docs: true.
  use ExUnit.Case, async: false

  alias Core.OptionsDocsTest.Server
  alias Core.OptionsDocsTest.Subject

  @section """
  ## Опции

  * `:size` (`t:pos_integer/0`) - Размер. The default value is `10`.

  * `:mode` - Required. Режим.

  """

  # `Code.fetch_docs/1` читает документацию из `.beam` на пути кода: у модуля, собранного в памяти,
  # её нет, а `mix test` собирает с `docs: false`.
  @fixtures ~S'''
  defmodule Core.OptionsDocsTest.Subject do
    @moduledoc "Функции со схемой опций."

    use Core.Options

    @schema [
      size: [type: :pos_integer, default: 10, doc: "Размер."],
      mode: [type: {:in, ~w(fast slow)a}, required: true, doc: "Режим."]
    ]

    @doc """
    Текст автора.

    Второй абзац.
    """
    @opts_schema @schema
    def documented(opts), do: opts

    @opts_schema @schema
    def bare(opts), do: opts

    @doc false
    @opts_schema [size: [type: :pos_integer, default: 10, doc: "Размер."]]
    def hidden(opts), do: opts

    @doc "Голова без тела."
    @opts_schema @schema
    def head(subject, opts \\ [])

    def head(:a, opts), do: opts
    def head(:b, opts), do: opts

    @doc "Без схемы."
    def plain(opts), do: opts
  end

  defmodule Core.OptionsDocsTest.Server do
    @init_opts_schema [
      size: [type: :pos_integer, default: 10, doc: "Размер."],
      mode: [type: {:in, ~w(fast slow)a}, required: true, doc: "Режим."]
    ]

    @moduledoc """
    Процесс со скрытым `init/1`.

    ## Опции

    #{Core.Options.docs(@init_opts_schema)}
    """

    use GenServer
    use Core.Options

    @opts_schema @init_opts_schema
    @impl true
    def init(opts), do: {:ok, opts}
  end
  '''

  setup_all do
    dir = Path.join(System.tmp_dir!(), "options-docs-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    fixtures = compile_with_docs(@fixtures)

    for {module, binary} <- fixtures,
        do: File.write!(Path.join(dir, "#{module}.beam"), binary)

    true = :code.add_patha(to_charlist(dir))

    on_exit(fn ->
      for {module, _binary} <- fixtures do
        :code.delete(module)
        :code.purge(module)
      end

      :code.del_path(to_charlist(dir))
      File.rm_rf!(dir)
    end)
  end

  describe "раздел «Опции» в @doc" do
    test "дописывается после текста автора" do
      assert doc(Subject, :documented, 1) == "Текст автора.\n\nВторой абзац.\n\n" <> @section
    end

    test "функция без @doc получает @doc из одного раздела" do
      assert doc(Subject, :bare, 1) == @section
    end

    test "при @doc false не дописывается" do
      assert doc(Subject, :hidden, 1) == :hidden
    end

    test "голова без тела несёт текст автора и раздел" do
      assert doc(Subject, :head, 2) == "Голова без тела.\n\n" <> @section
    end

    test "функция без схемы — @doc автора как есть" do
      assert doc(Subject, :plain, 1) == "Без схемы."
    end

    test "@impl без @doc остаётся скрытым" do
      assert doc(Server, :init, 1) == :hidden
    end
  end

  describe "docs/1" do
    test "описание опций для @moduledoc" do
      assert moduledoc(Server) == "Процесс со скрытым `init/1`.\n\n" <> @section <> "\n"
    end

    test "некорректная схема — ArgumentError" do
      assert_raise ArgumentError, ~r/invalid NimbleOptions schema/, fn ->
        Core.Options.docs(size: [type: :no_such_type, doc: "Размер."])
      end
    end

    test "ключ без doc: — ArgumentError" do
      assert_raise ArgumentError, ~r/^Core\.Options\.docs\/1: ключи без doc: строкой: \[:size\]$/, fn ->
        Core.Options.docs(size: [type: :pos_integer])
      end
    end
  end

  # ---

  defp doc(module, name, arity) do
    {:docs_v1, _anno, _lang, _format, _moduledoc, _meta, docs} = Code.fetch_docs(module)

    case List.keyfind(docs, {:function, name, arity}, 0) do
      {_key, _anno, _signature, %{"en" => text}, _meta} -> text
      {_key, _anno, _signature, :hidden, _meta} -> :hidden
    end
  end

  defp moduledoc(module) do
    {:docs_v1, _anno, _lang, _format, %{"en" => text}, _meta, _docs} = Code.fetch_docs(module)
    text
  end

  defp compile_with_docs(source) do
    docs = Code.get_compiler_option(:docs)
    Code.put_compiler_option(:docs, true)

    try do
      Code.compile_string(source)
    after
      Code.put_compiler_option(:docs, docs)
    end
  end
end
