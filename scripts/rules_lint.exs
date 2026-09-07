# Проверка свода правил `docs/rules` на соответствие стандарту (`docs/rules/00-index.md`):
# форма файлов, карта свода, доставка скиллами.
# Запуск: elixir scripts/rules_lint.exs  (цель `make rules-check`).

defmodule RulesLint do
  @moduledoc false

  @dir "docs/rules"
  @skills_dir ".claude/skills"
  @entry "AGENTS.md"
  @index "00-index.md"
  @always_on "20-agreements.md"
  @header_keys ["**Область.**", "**Читать перед.**", "**Словарь.**"]
  @tail "## Связанные правила"
  @max_len 100

  @vague [~r/по возможности/iu, ~r/желательн/iu, ~r/старайтесь/iu]
  @modality ~r/\b(MUST|SHOULD|MAY)\b/

  @link ~r/`(\d\d-[a-z0-9-]+\.md)`/
  @external_marker ~r/свод[а-яё]*\s+приложения/iu

  def run do
    files = @dir |> Path.join("[0-9][0-9]-*.md") |> Path.wildcard() |> Enum.sort()

    if files == [] do
      abort(["#{@dir}: файлов свода не найдено"])
    end

    known = MapSet.new(files, &Path.basename/1)

    errors =
      Enum.flat_map(files, &check_file(&1, known)) ++
        check_map(files) ++ check_skills(files) ++ check_entry(files)

    case errors do
      [] -> IO.puts("rules-check: #{length(files)} файлов, нарушений нет")
      errors -> abort(errors)
    end
  end

  # ---

  defp abort(errors) do
    Enum.each(errors, &IO.puts(:stderr, &1))
    IO.puts(:stderr, "\nrules-check: нарушений — #{length(errors)}; стандарт — #{@dir}/#{@index}")
    System.halt(1)
  end

  defp check_file(path, known) do
    lines = path |> File.read!() |> String.split("\n")
    marked = mark_fences(lines)

    check_h1(path, marked) ++
      check_header(path, marked) ++
      check_tail(path, marked) ++
      check_depth(path, marked) ++
      check_fence_lang(path, marked) ++
      check_length(path, marked) ++
      check_links(path, marked, known) ++
      check_vague(path, marked)
  end

  # Каждой строке приписывается: номер, признак «внутри fenced-блока» и открывающий fence.
  defp mark_fences(lines) do
    {marked, open} =
      lines
      |> Enum.with_index(1)
      |> Enum.map_reduce(nil, fn {line, no}, open ->
        case {open, Regex.run(~r/^(`{3,})(.*)$/, line)} do
          {nil, [_, ticks, info]} ->
            {{no, line, false, {:open, ticks, String.trim(info)}}, ticks}

          {ticks, [_, close, ""]} when byte_size(close) >= byte_size(ticks) ->
            {{no, line, true, nil}, nil}

          {nil, _} ->
            {{no, line, false, nil}, nil}

          {_ticks, _} ->
            {{no, line, true, nil}, open}
        end
      end)

    if open, do: raise("#{__MODULE__}: незакрытый fenced-блок"), else: marked
  end

  defp check_h1(path, marked) do
    heads = for {no, line, false, _} <- marked, String.starts_with?(line, "# "), do: no
    first = Enum.find(marked, fn {_, line, _, _} -> String.trim(line) != "" end)

    cond do
      heads == [] -> [err(path, 1, "нет заголовка H1")]
      length(heads) > 1 -> [err(path, Enum.at(heads, 1), "H1 больше одного")]
      first && elem(first, 0) != hd(heads) -> [err(path, 1, "H1 не первая строка файла")]
      true -> []
    end
  end

  defp check_header(path, marked) do
    keys =
      marked
      |> Enum.take_while(fn {_, line, in_fence, _} ->
        in_fence or not String.starts_with?(line, "## ")
      end)
      |> Enum.filter(fn {_, line, in_fence, _} ->
        not in_fence and String.starts_with?(line, "- **")
      end)
      |> Enum.map(fn {_, line, _, _} ->
        line |> then(&Regex.run(~r/^- (\*\*[^*]+\*\*)/, &1)) |> Enum.at(1)
      end)

    if keys == @header_keys,
      do: [],
      else: [
        err(
          path,
          2,
          "шапка: ожидаются пункты #{Enum.join(@header_keys, ", ")}, найдено: #{inspect(keys)}"
        )
      ]
  end

  defp check_tail(path, marked) do
    h2 =
      for {no, line, false, _} <- marked,
          String.starts_with?(line, "## "),
          do: {no, String.trim(line)}

    case List.last(h2) do
      {_, @tail} -> []
      {no, other} -> [err(path, no, "последний H2 — «#{other}», ожидается «#{@tail}»")]
      nil -> [err(path, 1, "нет секции «#{@tail}»")]
    end
  end

  defp check_depth(path, marked) do
    for {no, line, false, _} <- marked, Regex.match?(~r/^\#{4,} /, line) do
      err(path, no, "заголовок глубже H3")
    end
  end

  defp check_fence_lang(path, marked) do
    for {no, _line, _, {:open, _ticks, info}} <- marked, info == "" do
      err(path, no, "fenced-блок без языка")
    end
  end

  defp check_length(path, marked) do
    for {no, line, false, nil} <- marked,
        String.length(line) > @max_len,
        not String.starts_with?(String.trim_leading(line), "|"),
        String.contains?(String.trim(line), " ") do
      err(path, no, "строка #{String.length(line)} символов > #{@max_len}")
    end
  end

  # Пометка «(свод приложения)» ищется в пределах абзаца: ссылка и пометка могут
  # оказаться на разных строках после переноса.
  defp check_links(path, marked, known) do
    for {no, line, false, _} <- marked,
        [_, target] <- Regex.scan(@link, line),
        not MapSet.member?(known, target),
        not Regex.match?(@external_marker, paragraph(marked, no)) do
      err(path, no, "ссылка `#{target}` не резолвится и не помечена «(свод приложения)»")
    end
  end

  # Абзац, которому принадлежит строка: соседние непустые строки вне fenced-блоков.
  defp paragraph(marked, no) do
    text = fn {_, line, _, _} -> line end
    blank? = fn {_, line, _, _} -> String.trim(line) == "" end

    before = marked |> Enum.take(no - 1) |> Enum.reverse() |> Enum.take_while(&(not blank?.(&1)))
    rest = marked |> Enum.drop(no - 1) |> Enum.take_while(&(not blank?.(&1)))

    (Enum.reverse(before) ++ rest) |> Enum.map_join(" ", text)
  end

  defp check_vague(path, marked) do
    for {no, line, false, _} <- marked,
        Enum.any?(@vague, &Regex.match?(&1, line)),
        not Regex.match?(@modality, line) do
      err(path, no, "расплывчатая формулировка без MUST / SHOULD / MAY")
    end
  end

  # Карта свода в `00-index.md` и набор файлов совпадают в обе стороны.
  defp check_map(files) do
    index = Path.join(@dir, @index)

    listed =
      index
      |> File.read!()
      |> then(&Regex.scan(~r/^\| `(\d\d-[a-z0-9-]+\.md)`/m, &1))
      |> Enum.map(&Enum.at(&1, 1))

    actual = files |> Enum.map(&Path.basename/1) |> Enum.reject(&(&1 == @index))

    missing =
      for f <- actual, f not in listed, do: err(index, 1, "файл `#{f}` отсутствует в карте свода")

    extra =
      for f <- listed,
          f not in actual,
          do: err(index, 1, "карта свода ссылается на несуществующий `#{f}`")

    missing ++ extra
  end

  # У каждого свода, кроме индекса и всегда-загруженных соглашений, есть skill-указатель.
  defp check_skills(files) do
    files
    |> Enum.map(&Path.basename/1)
    |> Enum.reject(&(&1 in [@index, @always_on]))
    |> Enum.flat_map(&check_skill/1)
  end

  defp check_skill(file) do
    name = file |> String.replace(~r/^\d\d-/, "") |> String.replace_suffix(".md", "")
    path = Path.join([@skills_dir, name, "SKILL.md"])

    if File.exists?(path) do
      content = File.read!(path)

      [
        {Regex.match?(~r/^name: #{name}$/m, content), "frontmatter `name:` не равен `#{name}`"},
        {Regex.match?(~r/^description: ".{80,}"$/m, content),
         "нет содержательного `description:`"},
        {String.contains?(content, "docs/rules/#{file}"),
         "тело не ссылается на `docs/rules/#{file}`"}
      ]
      |> Enum.reject(&elem(&1, 0))
      |> Enum.map(&err(path, 1, elem(&1, 1)))
    else
      [err(path, 1, "нет skill-указателя на `#{file}` (имя скилла — `#{name}`)")]
    end
  end

  # Карта в точке входа (`AGENTS.md`, на неё симлинк `CLAUDE.md`) и набор файлов совпадают.
  defp check_entry(files) do
    content = File.read!(@entry)
    actual = Enum.map(files, &Path.basename/1)

    listed =
      ~r/docs\/rules\/(\d\d-[a-z0-9-]+\.md)/ |> Regex.scan(content) |> Enum.map(&Enum.at(&1, 1))

    missing =
      for f <- actual, f not in listed, do: err(@entry, 1, "свод `#{f}` отсутствует в карте")

    extra =
      for f <- listed,
          f not in actual,
          do: err(@entry, 1, "карта ссылается на несуществующий `#{f}`")

    missing ++ Enum.uniq(extra)
  end

  defp err(path, line, message), do: "#{path}:#{line}: #{message}"
end

RulesLint.run()
