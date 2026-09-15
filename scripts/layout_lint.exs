# Раскладка модуля: маркеры `# ---` (падение уровня абстракции) и `# ===== <имя> =====`
# (граница блока) — `docs/rules/20-agreements.md`, «Разделители внутри модуля». Проверка идёт
# по AST плюс исходным строкам: маркер — комментарий, и в AST его нет.
# Запуск: elixir scripts/layout_lint.exs  (цель `make layout-check`).
#
# `lib/**` и `test/support/**` проверяются целиком; в остальных `test/**` разметка
# добровольна — проверяется только форма маркеров.

defmodule LayoutLint do
  @moduledoc false

  @rules "docs/rules/20-agreements.md"
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
    full = @full |> Enum.flat_map(&Path.wildcard/1) |> MapSet.new()
    form = @form |> Enum.flat_map(&Path.wildcard/1) |> Enum.reject(&MapSet.member?(full, &1))

    Enum.sort(Enum.map(full, &{&1, :full}) ++ Enum.map(form, &{&1, :form}))
  end

  defp abort(errors) do
    errors
    |> Enum.sort_by(fn {path, line, _} -> {path, line} end)
    |> Enum.each(fn {path, line, message} -> IO.puts(:stderr, "#{path}:#{line}: #{message}") end)

    IO.puts(:stderr, "\nlayout-check: нарушений — #{length(errors)}; правила — #{@rules}")
    System.halt(1)
  end

  defp check_file(path, mode) do
    source = File.read!(path)
    code = code_lines(path, source)
    nodes = source |> Code.string_to_quoted!(columns: true, token_metadata: true) |> collect()

    nodes
    |> units(markers(code))
    |> Enum.flat_map(&check_unit(&1, code, mode, path))
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
        defs: nodes.defs |> Enum.filter(own) |> Enum.sort_by(& &1.line),
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

  defp node({kind, meta, [_head | _]} = ast, nodes) when kind in @publics or kind in @privates do
    definition = %{line: meta[:line], column: meta[:column], kind: visibility(kind)}
    {ast, %{nodes | defs: [definition | nodes.defs]}}
  end

  defp node(ast, nodes), do: {ast, nodes}

  defp visibility(kind), do: if(kind in @publics, do: :public, else: :private)

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
    indent = def_indent(unit)
    form = Enum.flat_map(unit.markers, &check_form(&1, unit, code, indent, path))

    if mode == :form,
      do: form,
      else: form ++ check_transitions(unit, path) ++ check_blocks(unit, path)
  end

  defp def_indent(%{defs: [], module: module}), do: module.column + 1
  defp def_indent(%{defs: defs}), do: defs |> Enum.map(& &1.column) |> Enum.min() |> Kernel.-(1)

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

    blocks
    |> Enum.reject(fn block -> Enum.any?(block.defs, &(&1.kind == :public)) end)
    |> Enum.flat_map(&check_private_block(&1, &1 == last, unit, path))
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
