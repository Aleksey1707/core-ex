# Раскладка модуля: маркеры `# ---` (падение уровня абстракции) и `# ===== <имя> =====`
# (граница блока) и блок приватного по его вызывающим — `docs/rules/20-agreements.md`,
# «Разделители внутри модуля». Проверка идёт по AST плюс исходным строкам: маркер —
# комментарий, и в AST его нет.
# Запуск: elixir scripts/layout_lint.exs  (цель `make layout-check`); у потребителя —
# elixir deps/core/scripts/layout_lint.exs, и путь правил в сообщениях — `deps/core/…`.
#
# `lib/**` и `test/support/**` проверяются целиком; в остальных `test/**` разметка
# добровольна — проверяется только форма маркеров.

defmodule LayoutLint do
  @moduledoc false

  @rules "docs/rules/20-agreements.md"
  @dep_rules_dir "deps/core/docs/rules"
  @shared_block "общее"
  @full ["lib/**/*.{ex,exs}", "test/support/**/*.{ex,exs}"]
  @form ["test/**/*.{ex,exs}"]

  @modules ~w(defmodule defimpl defprotocol)a
  @publics ~w(def defmacro defguard defdelegate)a
  @privates ~w(defp defmacrop defguardp)a
  @attached ~w(@doc @spec @impl @deprecated @since)

  @heredoc_open ~r/"""\s*$/
  @heredoc_close ~r/^\s*"""/

  @candidate ~r/^\s*#\s*(-{2,}\s*$|={3,})/
  @dash ~r/^ *# ---$/
  @block ~r/^ *# ===== ([^=\s]|[^=\s].*[^=\s]) =====$/

  @spec run() :: :ok

  def run do
    files = files()
    errors = Enum.flat_map(files, fn {path, mode} -> check_file(path, mode) end)

    case errors do
      [] -> IO.puts("layout-check: #{length(files)} файлов, нарушений нет")
      errors -> abort(errors)
    end
  end

  # ---

  defp files do
    full = MapSet.new(Enum.flat_map(@full, &Path.wildcard/1))
    form = Enum.reject(Enum.flat_map(@form, &Path.wildcard/1), &MapSet.member?(full, &1))

    Enum.sort(Enum.map(full, &{&1, :full}) ++ Enum.map(form, &{&1, :form}))
  end

  defp abort(errors) do
    errors
    |> Enum.sort_by(fn {path, line, _} -> {path, line} end)
    |> Enum.each(fn {path, line, message} -> IO.puts(:stderr, "#{path}:#{line}: #{message}") end)

    IO.puts(:stderr, "\nlayout-check: нарушений — #{length(errors)}; правила — #{rules()}")
    System.halt(1)
  end

  # У потребителя свод приехал зависимостью: его `docs/rules/` — уже локальный свод.
  defp rules do
    if File.dir?(@dep_rules_dir),
      do: Path.join("deps/core", @rules),
      else: @rules
  end

  defp check_file(path, mode) do
    source = File.read!(path)
    code = code_lines(path, source)
    nodes = collect(Code.string_to_quoted!(source, columns: true, token_metadata: true))
    markers = markers(code)

    quoted =
      if mode == :full,
        do: check_quoted(markers, nodes, path),
        else: []

    quoted ++
      (nodes
       |> units(markers)
       |> Enum.flat_map(&check_unit(&1, code, mode, path)))
  end

  # Тело heredoc гасится: маркер ищется в коде, а не в примере внутри `@moduledoc`. Закрывающая
  # строка остаётся — она не пустая.
  defp code_lines(path, source) do
    {lines, open?} =
      source
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.map_reduce(false, fn {line, no}, open -> heredoc(line, no, open) end)

    if open?, do: raise("#{path}: незакрытый heredoc"), else: Map.new(lines)
  end

  # Открывает heredoc строка, кончающаяся тройной кавычкой; закрывает — начинающаяся с неё.
  defp heredoc(line, no, false), do: {{no, line}, Regex.match?(@heredoc_open, line)}

  defp heredoc(line, no, true) do
    if Regex.match?(@heredoc_close, line),
      do: {{no, line}, false},
      else: {{no, ""}, true}
  end

  defp markers(code) do
    code
    |> Enum.filter(fn {_no, line} -> Regex.match?(@candidate, line) end)
    |> Enum.map(fn {no, line} ->
      %{line: no, indent: indent(line), kind: kind(line), text: line}
    end)
    |> Enum.sort_by(& &1.line)
  end

  defp kind(line), do: if(String.contains?(line, "="), do: :block, else: :dash)

  defp indent(line), do: String.length(line) - String.length(String.trim_leading(line))

  # Единица — модуль (`defmodule` / `defimpl` / `defprotocol`): свои определения, свои маркеры,
  # свой счёт блоков. Вложенный модуль забирает своё у родителя, `quote` не отдаёт ничего никому.
  defp units(nodes, markers) do
    modules = Enum.sort_by(nodes.modules, & &1.line)

    for module <- modules do
      own = &(innermost(&1.line, modules) == module and not quoted?(&1.line, nodes.quotes))

      %{
        module: module,
        defs: Enum.sort_by(Enum.filter(nodes.defs, own), & &1.line),
        markers: Enum.filter(markers, own)
      }
    end
  end

  defp innermost(line, modules) do
    modules
    |> Enum.filter(&(line > &1.line and line <= &1.end_line))
    |> Enum.max_by(& &1.line, fn -> nil end)
  end

  defp quoted?(line, quotes),
    do: Enum.any?(quotes, fn {from, to} -> line > from and line <= to end)

  # Код `quote` инжектится в чужой модуль: разделитель внутри него размечал бы модуль, которого
  # здесь не видно, поэтому в единицы он не попадает, а здесь — нарушение.
  defp check_quoted(markers, nodes, path) do
    for marker <- markers, quoted?(marker.line, nodes.quotes) do
      err(path, marker.line, "маркер внутри `quote` MUST NOT: он размечает модуль, куда инжектится код")
    end
  end

  defp collect(ast) do
    {_ast, nodes} = Macro.prewalk(ast, %{modules: [], defs: [], quotes: []}, &node/2)
    nodes
  end

  defp node({kind, meta, args} = ast, nodes) when kind in @modules and is_list(args) do
    module = %{line: meta[:line], end_line: end_line(meta, ast), column: meta[:column]}
    {ast, %{nodes | modules: [module | nodes.modules]}}
  end

  defp node({:quote, meta, args} = ast, nodes) when is_list(args) do
    {ast, %{nodes | quotes: [{meta[:line], end_line(meta, ast)} | nodes.quotes]}}
  end

  defp node({kind, meta, [head | rest]} = ast, nodes) when kind in @publics or kind in @privates do
    {name, arities} = signature(head)

    definition = %{
      line: meta[:line],
      column: meta[:column],
      kind: visibility(kind),
      name: name,
      arities: arities,
      calls: calls([head | rest], MapSet.new())
    }

    {ast, %{nodes | defs: [definition | nodes.defs]}}
  end

  defp node(ast, nodes), do: {ast, nodes}

  defp visibility(kind), do: if(kind in @publics, do: :public, else: :private)

  # Имя и арности определения: аргумент со значением по умолчанию даёт несколько арностей.
  defp signature({:when, _, [call | _guards]}), do: signature(call)
  defp signature({name, _, context}) when is_atom(name) and is_atom(context), do: {name, [0]}

  defp signature({name, _, args}) when is_atom(name) and is_list(args) do
    defaults = Enum.count(args, &match?({:\\, _, _}, &1))
    {name, Enum.to_list((length(args) - defaults)..length(args))}
  end

  defp signature(_head), do: {nil, []}

  # Локальные вызовы головы (guard, умолчания) и тела: `f(x)`, `x |> f()`, `x |> f`, `&f/1`.
  # Код `quote` — чужой модуль: из него в счёт идут опции (`bind_quoted:`) и `unquote` — они
  # вычисляются здесь; при `unquote: false` — только опции.
  defp calls({:quote, _, args}, acc) when is_list(args) do
    {body, quote_opts} = Keyword.split(Enum.concat(Enum.filter(args, &is_list/1)), [:do])
    acc = calls(Keyword.values(quote_opts), acc)

    if Keyword.get(quote_opts, :unquote) == false,
      do: acc,
      else: unquotes(Keyword.values(body), acc)
  end

  defp calls({:|>, _, [left, {name, _, args}]}, acc) when is_atom(name) and is_list(args),
    do: calls(args, calls(left, MapSet.put(acc, {name, length(args) + 1})))

  defp calls({:|>, _, [left, {name, _, context}]}, acc) when is_atom(name) and is_atom(context),
    do: calls(left, MapSet.put(acc, {name, 1}))

  defp calls({:&, _, [{:/, _, [{name, _, context}, arity]}]}, acc)
       when is_atom(name) and is_atom(context) and is_integer(arity),
       do: MapSet.put(acc, {name, arity})

  defp calls({name, _, args}, acc) when is_atom(name) and is_list(args),
    do: calls(args, MapSet.put(acc, {name, length(args)}))

  defp calls({callee, _, args}, acc) when is_list(args), do: calls(args, calls(callee, acc))
  defp calls({left, right}, acc), do: calls(right, calls(left, acc))
  defp calls(list, acc) when is_list(list), do: Enum.reduce(list, acc, &calls/2)
  defp calls(_leaf, acc), do: acc

  defp unquotes({kind, _, [expr]}, acc) when kind in ~w(unquote unquote_splicing)a, do: calls(expr, acc)
  defp unquotes({callee, _, args}, acc) when is_list(args), do: unquotes(args, unquotes(callee, acc))
  defp unquotes({left, right}, acc), do: unquotes(right, unquotes(left, acc))
  defp unquotes(list, acc) when is_list(list), do: Enum.reduce(list, acc, &unquotes/2)
  defp unquotes(_leaf, acc), do: acc

  defp end_line(meta, ast) do
    {_ast, last} =
      Macro.prewalk(ast, meta[:line], fn node, acc -> {node, max(acc, last_line(node))} end)

    last
  end

  defp last_line({_form, meta, _args}) when is_list(meta) do
    Enum.max([
      meta[:line] || 0,
      get_in(meta, [:end, :line]) || 0,
      get_in(meta, [:closing, :line]) || 0
    ])
  end

  defp last_line(_node), do: 0

  defp check_unit(unit, code, mode, path) do
    form = Enum.flat_map(unit.markers, &check_form(&1, unit, code, marker_indent(&1, unit), path))

    if mode == :form,
      do: form,
      else: form ++ check_transitions(unit, path) ++ check_blocks(unit, path) ++ check_placement_by_callers(unit, path)
  end

  # Отступ маркера — как у определений модуля либо как у определения под ним: определения
  # условной сборки (`if Code.ensure_loaded?(…)`) стоят глубже остальных.
  defp marker_indent(%{indent: indent} = marker, unit) do
    case Enum.find(unit.defs, &(&1.line > marker.line)) do
      %{column: column} when column - 1 == indent -> indent
      _below -> def_indent(unit)
    end
  end

  defp def_indent(%{defs: [], module: module}), do: module.column + 1
  defp def_indent(%{defs: defs}), do: Enum.min(Enum.map(defs, & &1.column)) - 1

  defp check_form(marker, unit, code, indent, path) do
    shape(marker, path) ++
      check_indent(marker, indent, path) ++
      check_blanks(marker, code, path) ++
      check_placement(marker, unit, code, indent, path)
  end

  defp shape(%{kind: :dash} = marker, path) do
    if Regex.match?(@dash, marker.text),
      do: [],
      else: [err(path, marker.line, "маркер не в форме `# ---`")]
  end

  defp shape(%{kind: :block} = marker, path) do
    if Regex.match?(@block, marker.text),
      do: [],
      else: [err(path, marker.line, "маркер не в форме `# ===== <имя> =====`")]
  end

  defp check_indent(%{indent: indent}, indent, _path), do: []

  defp check_indent(marker, indent, path) do
    [err(path, marker.line, "отступ маркера #{marker.indent}, у определений модуля #{indent}")]
  end

  defp check_blanks(marker, code, path) do
    for {no, where} <- [{marker.line - 1, "сверху"}, {marker.line + 1, "снизу"}],
        String.trim(Map.get(code, no, "")) != "" do
      err(path, marker.line, "нет пустой строки #{where} от маркера")
    end
  end

  # Маркер стоит перед `@doc` / `@spec` первой функции блока, а не между спекой и определением.
  defp check_placement(marker, unit, code, indent, path) do
    with %{line: line} <- Enum.find(unit.defs, &(&1.line > marker.line)),
         start when is_integer(start) <- attached_start(code, line, indent),
         true <- start < marker.line do
      [err(path, marker.line, "маркер внутри блока `@doc` / `@spec` — ставится перед ним")]
    else
      _ -> []
    end
  end

  # Начало блока `@doc` / `@spec` определения: вверх через пустые строки, комментарии и
  # продолжения спеки — до первой строки чужого уровня.
  defp attached_start(code, def_line, indent) do
    Enum.reduce_while((def_line - 1)..1//-1, nil, fn no, start ->
      line = Map.get(code, no, "")

      cond do
        String.trim(line) == "" -> {:cont, start}
        Regex.match?(@heredoc_close, line) -> {:cont, start}
        attached?(line) -> {:cont, no}
        String.starts_with?(String.trim_leading(line), "#") -> {:cont, start}
        indent(line) > indent -> {:cont, start}
        true -> {:halt, start}
      end
    end)
  end

  defp attached?(line) do
    trimmed = String.trim_leading(line)
    Enum.any?(@attached, &String.starts_with?(trimmed, &1))
  end

  defp check_transitions(unit, path) do
    unit.defs
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn [prev, next] -> transition(prev, next, unit, path) end)
  end

  defp transition(%{kind: kind}, %{kind: kind}, _unit, _path), do: []

  # Падение уровня на границе блока размечает сам маркер блока: `# ---` там MUST NOT.
  defp transition(prev, %{kind: :private} = next, unit, path) do
    if marked?(unit, prev, next, [:dash, :block]),
      do: [],
      else: [err(path, next.line, "переход public → private не предварён `# ---`")]
  end

  defp transition(prev, %{kind: :public} = next, unit, path) do
    if marked?(unit, prev, next, [:block]),
      do: [],
      else: [err(path, next.line, "возврат private → public не предварён `# ===== <имя> =====`")]
  end

  defp marked?(unit, prev, next, kinds) do
    Enum.any?(unit.markers, &(&1.kind in kinds and &1.line > prev.line and &1.line < next.line))
  end

  defp check_blocks(%{defs: []}, _path), do: []

  defp check_blocks(unit, path) do
    case Enum.filter(unit.markers, &(&1.kind == :block)) do
      [] ->
        []

      marks ->
        check_marked(marks, hd(unit.defs), path) ++ check_tail(blocks(marks, unit), unit, path)
    end
  end

  defp check_marked(marks, first, path) do
    cond do
      hd(marks).line > first.line ->
        [
          err(
            path,
            hd(marks).line,
            "первый блок не размечен: в модуле с ≥2 блоками размечен каждый"
          )
        ]

      length(marks) == 1 ->
        [err(path, hd(marks).line, "модуль с одним блоком: `# ===== <имя> =====` MUST NOT")]

      true ->
        []
    end
  end

  # Блок без публичных определений — хвостовой `общее`: только последний и без `# ---`.
  defp check_tail(blocks, unit, path) do
    last = List.last(blocks)

    (blocks
     |> Enum.reject(fn block -> Enum.any?(block.defs, &(&1.kind == :public)) end)
     |> Enum.flat_map(&check_private_block(&1, &1 == last, unit, path))) ++
      dash_before_shared(unit, path)
  end

  defp check_private_block(%{defs: []} = block, _last?, _unit, path),
    do: [err(path, block.from, "блок без определений — маркер не нужен")]

  defp check_private_block(block, true, unit, path), do: dashes(block, unit, path)

  defp check_private_block(block, false, _unit, path),
    do: [err(path, block.from, "блок без публичных определений — только последний в модуле")]

  defp dashes(block, unit, path) do
    for marker <- unit.markers,
        marker.kind == :dash,
        marker.line > block.from,
        marker.line < block.to do
      err(path, marker.line, "`# ---` в блоке без публичных определений")
    end
  end

  # Переход к приватным `общее` размечает сам маркер блока: `# ---` сразу перед ним лишний.
  defp dash_before_shared(unit, path) do
    unit.markers
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.filter(fn [dash, block] ->
      dash.kind == :dash and shared?(block) and
        not Enum.any?(unit.defs, &(&1.line > dash.line and &1.line < block.line))
    end)
    |> Enum.map(fn [dash, _block] ->
      err(path, dash.line, "`# ---` перед `# ===== #{@shared_block} =====` MUST NOT")
    end)
  end

  defp shared?(%{kind: :block, text: text}), do: String.trim(text) == "# ===== #{@shared_block} ====="
  defp shared?(_marker), do: false

  # Блок приватного — блок его вызывающих: один блок — он сам, несколько — хвостовой `общее`.
  # Вызывающие — определения модуля, прямые; рекурсия не в счёт. Модуль из одного блока не
  # проверяется: блок у всех один.
  defp check_placement_by_callers(%{defs: []}, _path), do: []

  defp check_placement_by_callers(unit, path) do
    case Enum.filter(unit.markers, &(&1.kind == :block)) do
      [_first, _second | _] = marks -> misplaced_privates(layout(marks, unit), unit, path)
      _single -> []
    end
  end

  defp layout(marks, unit) do
    blocks = blocks(marks, unit)
    names = Enum.map(blocks, &block_name(&1, marks))
    %{blocks: blocks, names: names, shared: Enum.find_index(names, &(&1 == @shared_block))}
  end

  defp misplaced_privates(layout, unit, path) do
    for clauses <- private_functions(unit),
        message = placement(clauses, unit, layout),
        message != nil do
      err(path, hd(clauses).line, message)
    end
  end

  # Функция — клаузы одного имени с общей арностью: голова с умолчаниями (`f/1`, `f/2`) и клаузы
  # `f/2` — одна функция, `f/1` и `f/2` без умолчаний — две.
  defp private_functions(unit) do
    unit.defs
    |> Enum.filter(&(&1.kind == :private and &1.name != nil))
    |> Enum.reduce([], fn clause, functions ->
      case Enum.split_with(functions, &same_function?(&1, clause)) do
        {[], rest} -> [[clause] | rest]
        {[function], rest} -> [function ++ [clause] | rest]
      end
    end)
    |> Enum.sort_by(&hd(&1).line)
  end

  defp same_function?([%{name: name} | _] = function, %{name: name, arities: arities}),
    do: Enum.any?(function, &Enum.any?(&1.arities, fn arity -> arity in arities end))

  defp same_function?(_function, _clause), do: false

  defp placement(clauses, unit, %{names: names, shared: shared} = layout) do
    name = hd(clauses).name
    signatures = for clause <- clauses, arity <- clause.arities, into: MapSet.new(), do: {name, arity}
    placed = block_index(hd(clauses), layout)
    label = "`#{name}/#{Enum.max(Enum.flat_map(clauses, & &1.arities))}`"

    callers =
      unit.defs
      |> Enum.filter(&(&1 not in clauses and not MapSet.disjoint?(&1.calls, signatures)))
      |> Enum.map(&block_index(&1, layout))
      |> Enum.uniq()
      |> Enum.sort()

    case callers do
      [] ->
        nil

      [^placed] ->
        nil

      [single] when placed == shared ->
        "в `общее` — только приватный, вызываемый из нескольких блоков; #{label} вызывает " <>
          "только блок «#{Enum.at(names, single)}» — его место там"

      [single] ->
        "приватный #{label} вызывает только блок «#{Enum.at(names, single)}» — его место там"

      _many when placed == shared ->
        nil

      many ->
        "приватный #{label} вызывают блоки #{Enum.map_join(many, ", ", &"«#{Enum.at(names, &1)}»")} — " <>
          "его место в `# ===== #{@shared_block} =====`"
    end
  end

  defp block_index(definition, %{blocks: blocks}),
    do: Enum.find_index(blocks, &(definition.line > &1.from and definition.line < &1.to))

  defp block_name(block, marks) do
    with %{text: text} <- Enum.find(marks, &(&1.line == block.from)),
         [_line, name] <- Regex.run(@block, text) do
      name
    else
      _unnamed -> "без имени"
    end
  end

  defp blocks(marks, unit) do
    bounds = Enum.map(marks, & &1.line)
    bounds = if hd(bounds) > hd(unit.defs).line, do: [unit.module.line | bounds], else: bounds
    ends = tl(bounds) ++ [unit.module.end_line + 1]

    for {from, to} <- Enum.zip(bounds, ends) do
      %{from: from, to: to, defs: Enum.filter(unit.defs, &(&1.line > from and &1.line < to))}
    end
  end

  defp err(path, line, message), do: {path, line, message}
end

LayoutLint.run()
