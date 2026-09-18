defmodule Core.Enum.DocsCaseTest do
  # async: false — фикстуры собираются с глобальной опцией компилятора docs: true.
  use ExUnit.Case, async: false

  alias Core.Enum.DocsCase
  alias Core.Enum.DocsCaseTest.Bare
  alias Core.Enum.DocsCaseTest.Coded
  alias Core.Enum.DocsCaseTest.Hidden
  alias Core.Enum.DocsCaseTest.Malformed
  alias Core.Enum.DocsCaseTest.NoTable
  alias Core.Enum.DocsCaseTest.Undocumented
  alias Core.Enum.DocsCaseTest.Unknown

  # `Code.fetch_docs/1` читает `@moduledoc` из `.beam` на пути кода: у модуля, собранного
  # в памяти, документации нет, а `mix test` собирает с `docs: false`. Сломанные enum не лежат
  # в test/support — их увидел бы тест-модуль самой библиотеки.
  @fixtures ~S'''
  defmodule Core.Enum.DocsCaseTest.Coded do
    @moduledoc """
    Описанный enum с кодами

    | Значение | Код | Описание |
    |---|---|---|
    | `:first` | 1 | первое |
    | `:second` | 2 | второе |

    | Переход | Описание |
    |---|---|
    | `:first` | не строка значения: таблица не `Значение` |
    | `:third` | не строка значения: таблица не `Значение` |
    """

    use Core.Enum,
      name: "Описанный enum с кодами",
      codes: %{first: 1, second: 2}
  end

  defmodule Core.Enum.DocsCaseTest.Undocumented do
    @moduledoc """
    Enum с неописанным значением

    | Значение | Описание |
    |---|---|
    | `:new` | создан |
    """

    use Core.Enum,
      name: "Enum с неописанным значением",
      values: ~w(new done)a
  end

  defmodule Core.Enum.DocsCaseTest.NoTable do
    @moduledoc """
    Enum без таблицы значений

    | Уровень | Описание |
    |---|---|
    | `:low` | не строка значения: таблица не `Значение` |
    """

    use Core.Enum,
      name: "Enum без таблицы значений",
      values: ~w(low high)a
  end

  defmodule Core.Enum.DocsCaseTest.Hidden do
    @moduledoc false

    use Core.Enum,
      name: "Enum со скрытой документацией",
      values: ~w(on off)a
  end

  defmodule Core.Enum.DocsCaseTest.Bare do
    use Core.Enum,
      name: "Enum без @moduledoc",
      values: ~w(yes no)a
  end

  defmodule Core.Enum.DocsCaseTest.Unknown do
    @moduledoc """
    Enum с описанием удалённого значения

    | Значение | Описание |
    |---|---|
    | `:active` | действует |
    | `:archived` | удалён из enum, описание осталось |
    """

    use Core.Enum,
      name: "Enum с описанием удалённого значения",
      values: ~w(active)a
  end

  defmodule Core.Enum.DocsCaseTest.Malformed do
    @moduledoc """
    Enum с ячейкой значения не в форме inspect/1

    | Значение | Описание |
    |---|---|
    | `:on` | включён |
    | off | выключен |
    """

    use Core.Enum,
      name: "Enum с ячейкой значения не в форме inspect/1",
      values: ~w(on off)a
  end
  '''

  setup_all do
    dir = Path.join(System.tmp_dir!(), "enum-docs-case-#{System.unique_integer([:positive])}")
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

  describe "enums!/1" do
    test "модули Core.Enum приложения, отсортированные" do
      enums = DocsCase.enums!(:core)

      for enum <- [Core.DurationParser.Rounding, Core.DurationParser.Unit, Core.Outbox.Status],
          do: assert(enum in enums)

      assert Core.ViewFixture.Status in enums
      assert Core.Web.Response.Code in enums
      assert enums == Enum.sort(enums)
    end

    test "модуль не enum не отбирается, в том числе Prim с name/0" do
      enums = DocsCase.enums!(:core)

      refute Core.Enum in enums
      refute Core.Mq.Topic in enums
    end

    test "приложение не загружено — ArgumentError" do
      assert_raise ArgumentError, ~r/приложение :missing_app не загружено/, fn ->
        DocsCase.enums!(:missing_app)
      end
    end

    test "в приложении нет enum — ArgumentError, а не проверка вхолостую" do
      assert_raise ArgumentError, ~r/в приложении :logger нет enum/, fn ->
        DocsCase.enums!(:logger)
      end
    end
  end

  describe "check_table/1" do
    test "у каждого enum есть таблица значений — :ok" do
      assert :ok = DocsCase.check_table([Coded, Undocumented])
    end

    test "нет @moduledoc и нет таблицы Значение — enum по причине" do
      assert {:error, %{no_moduledoc: [Hidden, Bare], no_table: [NoTable]}} =
               DocsCase.check_table([Coded, Hidden, NoTable, Bare])
    end
  end

  describe "check_undocumented/1" do
    test "каждое значение описано, прочие таблицы не мешают — :ok" do
      assert :ok = DocsCase.check_undocumented([Coded, Unknown])
    end

    test "значение без строки таблицы и с ячейкой не в форме inspect/1 — enum и значения" do
      assert {:error, %{undocumented: [{Undocumented, [:done]}, {Malformed, [:off]}]}} =
               DocsCase.check_undocumented([Coded, Undocumented, Malformed])
    end

    test "enum без таблицы значений не проверяется — его отчитывает check_table/1" do
      assert :ok = DocsCase.check_undocumented([Hidden, Bare, NoTable])
    end
  end

  describe "check_unknown/1" do
    test "таблица значений описывает только значения enum, прочие таблицы не разбираются — :ok" do
      assert :ok = DocsCase.check_unknown([Coded, Undocumented, NoTable, Hidden])
    end

    test "строка несуществующего значения и ячейка не в форме inspect/1 — enum и ячейки" do
      assert {:error, %{unknown: [{Unknown, ["`:archived`"]}, {Malformed, ["off"]}]}} =
               DocsCase.check_unknown([Coded, Unknown, Malformed])
    end
  end

  describe "опции" do
    test "без otp_app: — CompileError" do
      assert_raise CompileError, ~r/нет обязательных опций: \[:otp_app\]/, fn ->
        use_case(async: true)
      end
    end

    test "otp_app: не атом — CompileError" do
      assert_raise CompileError, ~r/otp_app: ожидается атом/, fn ->
        use_case(otp_app: "core")
      end
    end

    test "async: не boolean — CompileError" do
      assert_raise CompileError, ~r/async: ожидается boolean/, fn ->
        use_case(otp_app: :core, async: :yes)
      end
    end

    test "отклоняет неизвестную опцию" do
      assert_raise CompileError, ~r/неизвестные опции: \[:modules\]/, fn ->
        use_case(otp_app: :core, modules: [Coded])
      end
    end
  end

  # ---

  defp compile_with_docs(source) do
    docs = Code.get_compiler_option(:docs)
    Code.put_compiler_option(:docs, true)

    try do
      Code.compile_string(source)
    after
      Code.put_compiler_option(:docs, docs)
    end
  end

  defp use_case(opts) do
    Code.eval_quoted(
      quote do
        defmodule Core.Enum.DocsCaseTest.Docs do
          use Core.Enum.DocsCase, unquote(opts)
        end
      end
    )
  end
end
