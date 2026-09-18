defmodule Core.Enum.DocsCase do
  @moduledoc """
  Case-модуль описаний значений `Core.Enum`: у каждого значения enum приложения есть строка таблицы
  в `@moduledoc`.

      defmodule MyApp.EnumDocsTest do
        use Core.Enum.DocsCase,
          otp_app: :my_app,
          async: true
      end

  Один тест-модуль на приложение поверх `ExUnit.Case`. Имя атома — ярлык, а не объяснение: без
  проверки значение добавляется или удаляется молча, и таблица расходится с `values/0`
  (`11-domain.md`, «Описание значений в `@moduledoc`»).

  Enum — модули `otp_app:` (`Application.spec/2`), которые отбирает `Core.Enum.enum?/1`, а не
  эвристика по экспортам. Перечня нет: новый enum попадает под проверку сам. Ни одного enum —
  провал всех тестов модуля: неверный `otp_app:` иначе прошёл бы вхолостую.

  Таблица значений — таблица `@moduledoc` с заголовком `| Значение |` (`Code.fetch_docs/1` читает
  его из `.beam`); прочие таблицы не разбираются, даже если в первой колонке атомы. Строка
  описывает значение, если её первая ячейка — значение в форме `inspect/1` в обратных кавычках
  (`` `:in_work` ``); остальные колонки (`Код`, `Описание`) и содержание описания не проверяются.

  ## Генерируемые тесты

  1. у каждого enum есть таблица значений; провал — по причине: `no_moduledoc` (`@moduledoc false`,
     не задан, собран без документации) или `no_table`; тесты 2 и 3 такой enum пропускают;
  2. каждое значение `values/0` описано строкой таблицы;
  3. первая ячейка каждой строки таблицы — значение из `values/0`: описание удалённого значения
     читатель примет за действующее, а ячейка другой формы (`| in_work |`) не описывает ничего.

  Логика теста — функция `check_*` (`:ok | {:error, detail}`), сам тест — `assert :ok = …`:
  провал печатает enum и расхождение.

  ## Opts

  - `otp_app:` — приложение, чьи enum проверяются; не загружено — провал всех тестов модуля
  - `async:` — опция `ExUnit.Case`, необязательная, по умолчанию `true`; явное значение требует
    `Credo.Check.Refactor.PassAsyncInTestCases`
  """

  alias Core.Helper

  @label "Enum.DocsCase"
  @required_keys ~w(otp_app)a
  @optional_keys ~w(async)a
  @values_header "Значение"

  @typedoc """
  Enum без таблицы значений: без `@moduledoc` (`@moduledoc false`, не задан, собран без
  документации) либо без таблицы с заголовком `| Значение |` и строками.
  """
  @type no_table :: %{optional(:no_moduledoc) => [module()], optional(:no_table) => [module()]}

  @typedoc "Enum и его значения без строки таблицы."
  @type undocumented :: %{undocumented: [{module(), [atom()]}]}

  @typedoc "Enum и первые ячейки строк таблицы, которые не описывают его значения."
  @type unknown :: %{unknown: [{module(), [String.t()]}]}

  # ===== объявление =====

  @doc "Сгенерировать тесты описаний значений enum приложения."
  defmacro __using__(opts) do
    lit = Macro.expand_literals(opts, __CALLER__)
    Helper.Opts.validate!(lit, @required_keys, @optional_keys, @label)
    otp_app = Helper.Opts.atom!(lit, :otp_app, @label)
    async = async!(lit)

    quote do
      use ExUnit.Case, async: unquote(async)

      setup_all do
        %{enums: Core.Enum.DocsCase.enums!(unquote(otp_app))}
      end

      test "у каждого enum есть таблица значений в @moduledoc", %{enums: enums} do
        assert :ok = Core.Enum.DocsCase.check_table(enums)
      end

      test "каждое значение enum описано строкой таблицы в @moduledoc", %{enums: enums} do
        assert :ok = Core.Enum.DocsCase.check_undocumented(enums)
      end

      test "таблица в @moduledoc не описывает несуществующих значений", %{enums: enums} do
        assert :ok = Core.Enum.DocsCase.check_unknown(enums)
      end
    end
  end

  # ---

  defp async!(opts) do
    case Keyword.get(opts, :async, true) do
      async when is_boolean(async) ->
        async

      other ->
        raise CompileError,
          description: "#{@label}: async: ожидается boolean, получено #{inspect(other)}"
    end
  end

  # ===== enum приложения =====

  @doc false
  @spec enums!(atom()) :: [module()]

  def enums!(otp_app) when is_atom(otp_app) do
    with modules when is_list(modules) <- Application.spec(otp_app, :modules),
         [_ | _] = enums <- Enum.filter(modules, &Core.Enum.enum?/1) do
      Enum.sort(enums)
    else
      nil -> raise ArgumentError, "#{@label}: приложение #{inspect(otp_app)} не загружено"
      [] -> raise ArgumentError, "#{@label}: в приложении #{inspect(otp_app)} нет enum"
    end
  end

  # ===== таблица =====

  @doc false
  @spec check_table([module()]) :: :ok | {:error, no_table()}

  def check_table(enums) when is_list(enums) do
    case Enum.flat_map(enums, &missing_table/1) do
      [] -> :ok
      missing -> {:error, Enum.group_by(missing, &elem(&1, 0), &elem(&1, 1))}
    end
  end

  # ---

  defp missing_table(enum) do
    case value_cells(enum) do
      {:ok, [_ | _]} -> []
      {:ok, []} -> [no_table: enum]
      :no_moduledoc -> [no_moduledoc: enum]
    end
  end

  # ===== строки значений =====

  @doc false
  @spec check_undocumented([module()]) :: :ok | {:error, undocumented()}

  def check_undocumented(enums) when is_list(enums) do
    enums
    |> Enum.flat_map(&tables/1)
    |> Enum.flat_map(&undocumented/1)
    |> result(:undocumented)
  end

  @doc false
  @spec check_unknown([module()]) :: :ok | {:error, unknown()}

  def check_unknown(enums) when is_list(enums) do
    enums
    |> Enum.flat_map(&tables/1)
    |> Enum.flat_map(&unknown/1)
    |> result(:unknown)
  end

  # ---

  # Enum без таблицы значений пропускается: его отчитывает `check_table/1`.
  defp tables(enum) do
    case value_cells(enum) do
      {:ok, [_ | _] = cells} -> [{enum, cells}]
      _no_table -> []
    end
  end

  defp undocumented({enum, cells}) do
    enum.values()
    |> Enum.reject(&(cell(&1) in cells))
    |> mismatch(enum)
  end

  defp unknown({enum, cells}) do
    values = Enum.map(enum.values(), &cell/1)

    cells
    |> Enum.reject(&(&1 in values))
    |> mismatch(enum)
  end

  defp cell(value), do: "`#{inspect(value)}`"

  defp mismatch([], _enum), do: []
  defp mismatch(items, enum), do: [{enum, items}]

  defp result([], _key), do: :ok
  defp result(mismatches, key), do: {:error, %{key => mismatches}}

  # ===== общее =====

  defp value_cells(enum) do
    case Code.fetch_docs(enum) do
      {:docs_v1, _anno, _language, _format, %{"en" => doc}, _metadata, _docs} -> {:ok, table_cells(doc)}
      _hidden_none_or_error -> :no_moduledoc
    end
  end

  defp table_cells(doc) do
    doc
    |> String.split("\n")
    |> Enum.chunk_by(&table_line?/1)
    |> Enum.filter(&values_table?/1)
    |> Enum.flat_map(fn [_header, _separator | rows] -> Enum.map(rows, &first_cell/1) end)
  end

  defp values_table?([header, _separator | _rows]),
    do: table_line?(header) and first_cell(header) == @values_header

  defp values_table?(_lines), do: false

  defp table_line?(line), do: String.starts_with?(String.trim_leading(line), "|")

  defp first_cell(line) do
    line
    |> String.split("|", parts: 3)
    |> Enum.at(1, "")
    |> String.trim()
  end
end
