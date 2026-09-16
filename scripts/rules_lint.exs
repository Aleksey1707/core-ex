# Проверка свода правил на соответствие стандарту: форма файлов, карта свода, доставка
# скиллами и импортами, разрешимость ссылок.
#
#   elixir scripts/rules_lint.exs                       # библиотека (цель `make rules-check`)
#   elixir deps/core/scripts/rules_lint.exs --consumer   # приложение-потребитель
#
# Режим библиотеки проверяет два яруса разом: `docs/rules` по стандарту `docs/rules/00-index.md`
# и ярус потребителя `docs/rules/app` по стандарту `docs/rules/app/00-index.md` — та же форма,
# своя карта, скиллов нет, имён конкретных приложений быть не должно. Режим потребителя
# проверяет локальный свод `docs/rules`: его форму, карты и то, что ссылки на оба приехавших
# яруса разрешаются, а скиллы ведут на все файлы темы.
#
# Адресация ссылок общая для обоих режимов (`docs/rules/app/00-index.md`, «Адресация ссылок»):
# сосед по ярусу — именем файла, другой ярус — путём от корня потребителя (`deps/core/…`).
# В библиотеке префикс отбрасывается, и тот же путь разрешается в `docs/rules` и
# `docs/rules/app`. Стандарт ввела библиотека, поэтому инструмент живёт здесь: потребитель
# зовёт скрипт из `deps/core/scripts/`, своей копии не держит.

defmodule RulesLint do
  @moduledoc false

  @dir "docs/rules"
  @app_dir "docs/rules/app"
  @dep_dir "deps/core/docs/rules"
  @dep_app_dir "deps/core/docs/rules/app"
  @skills_dir ".claude/skills"
  @entry "AGENTS.md"
  @alias "CLAUDE.md"
  @index "00-index.md"
  @always_on "20-agreements.md"
  @header_keys ["**Область.**", "**Читать перед.**", "**Словарь.**"]
  @tail "## Связанные правила"
  @max_len 100

  @vague [~r/по возможности/iu, ~r/желательн/iu, ~r/старайтесь/iu]
  @modality ~r/\b(MUST|SHOULD|MAY)\b/

  @link ~r/`(\d\d-[a-z0-9-]+\.md)`/
  @bare_path ~r/`(docs\/rules\/(?:app\/)?\d\d-[a-z0-9-]+\.md)`/

  # Корень цепочки модулей в ярусе потребителя: либо библиотека, либо плейсхолдер приложения,
  # либо внешняя зависимость, либо конвенционный короткий алиас из примеров свода.
  @app_roots ~w(
    Core MyApp MyAppWeb
    Ecto ExUnit Credo Logger Oban Cachex Phoenix PromEx OpenApiSpex
    Consistency Design Readability Refactor Warning
    Application Enum Keyword Map Process String
    Actor Agg Caches Codec Config Context DAO Error Errors Es Event Helper InCodec OutCodec
    Outbox Params Prim Projection Projections Repo ReadRepo Response Result Schema Sc
    Specs Status Step Steps Store Transact Usecases Version View Workers
  )
  @module_ref ~r/(?<![\w.])([A-Z][A-Za-z0-9]*)\.[A-Z][A-Za-z0-9]*/

  def run([]), do: check(:library)

  def run(["--consumer"]), do: check(:consumer)

  def run(argv) do
    IO.puts(:stderr, "rules-check: неизвестные аргументы #{inspect(argv)}")
    IO.puts(:stderr, "  elixir scripts/rules_lint.exs [--consumer]")
    System.halt(2)
  end

  # ---

  # В библиотеке ссылка `deps/core/…` разрешается отбрасыванием префикса: файлы обоих ярусов
  # лежат здесь же.
  defp check(:library) do
    files = rules(@dir)
    app_files = rules(@app_dir)

    if files == [], do: abort(["#{@dir}: файлов свода не найдено"])
    if app_files == [], do: abort(["#{@app_dir}: файлов свода потребителя не найдено"])

    known = MapSet.new(files, &Path.basename/1)
    app_known = MapSet.new(app_files, &Path.basename/1)
    tiers = [{@dep_dir, @dir}, {@dep_app_dir, @app_dir}]

    (Enum.flat_map(files, &check_file(&1, known, tiers)) ++
       Enum.flat_map(app_files, &check_app_file(&1, app_known, tiers)) ++
       check_map(files, @dir) ++
       check_map(app_files, @app_dir) ++
       check_skills(files, []) ++
       check_entry(files) ++ check_imports([@dir]) ++ check_alias())
    |> report(length(files) + length(app_files))
  end

  # У потребителя проверяется его собственный свод; ярусы приехали в `deps/core` и проверены
  # в библиотеке — от них нужна только разрешимость ссылок и доставка.
  defp check(:consumer) do
    files = rules(@dir)

    if files == [], do: abort(["#{@dir}: файлов свода не найдено"])

    known = MapSet.new(files, &Path.basename/1)
    tiers = [{@dep_dir, @dep_dir}, {@dep_app_dir, @dep_app_dir}]

    (Enum.flat_map(files, &check_file(&1, known, tiers)) ++
       check_map(files, @dir) ++
       check_skills(files, [@dep_dir, @dep_app_dir]) ++
       check_entry(files) ++ check_imports([@dep_dir, @dep_app_dir, @dir]) ++ check_alias())
    |> report(length(files))
  end

  defp rules(dir), do: dir |> Path.join("[0-9][0-9]-*.md") |> Path.wildcard() |> Enum.sort()

  defp report([], count), do: IO.puts("rules-check: #{count} файлов, нарушений нет")

  defp report(errors, _count), do: abort(errors)

  defp abort(errors) do
    Enum.each(errors, &IO.puts(:stderr, &1))
    IO.puts(:stderr, "\nrules-check: нарушений — #{length(errors)}; стандарт — #{@dir}/#{@index}")
    System.halt(1)
  end

  # ===== форма файла =====

  defp check_file(path, known, tiers) do
    lines = path |> File.read!() |> String.split("\n")
    marked = mark_fences(lines)

    check_h1(path, marked) ++
      check_header(path, marked) ++
      check_tail(path, marked) ++
      check_depth(path, marked) ++
      check_fence_lang(path, marked) ++
      check_length(path, marked) ++
      check_links(path, marked, known) ++
      check_bare_paths(path, marked) ++
      Enum.flat_map(tiers, fn {prefix, dir} -> check_tier_links(path, marked, prefix, dir) end) ++
      check_vague(path, marked)
  end

  # Ярус потребителя: та же форма плюс запрет имён конкретных приложений.
  defp check_app_file(path, known, tiers) do
    marked = path |> File.read!() |> String.split("\n") |> mark_fences()

    check_file(path, known, tiers) ++ check_app_names(path, marked)
  end

  # ---

  # В ярусе потребителя норма записывается плейсхолдерами: имя конкретного приложения
  # превращает её в пересказ чужого кода (`docs/rules/app/00-index.md`).
  defp check_app_names(path, marked) do
    for {no, line, _in_fence, _} <- marked,
        [_, root] <- Regex.scan(@module_ref, line),
        root not in @app_roots do
      err(path, no, "корень `#{root}` не плейсхолдер и не известная зависимость")
    end
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

  defp check_vague(path, marked) do
    for {no, line, false, _} <- marked,
        Enum.any?(@vague, &Regex.match?(&1, line)),
        not Regex.match?(@modality, line) do
      err(path, no, "расплывчатая формулировка без MUST / SHOULD / MAY")
    end
  end

  # ===== адресация ссылок =====

  # Именем файла адресуется сосед по своему ярусу; имя без файла — оборванная ссылка.
  defp check_links(path, marked, known) do
    for {no, line, false, _} <- marked,
        [_, target] <- Regex.scan(@link, line),
        not MapSet.member?(known, target) do
      err(path, no, "ссылка `#{target}` не резолвится рядом — сосед по ярусу?")
    end
  end

  # Путь без префикса у потребителя ведёт в его локальный свод, то есть в файл соседнего
  # яруса с тем же именем; отличить это от опечатки нельзя ни читателю, ни проверке.
  defp check_bare_paths(path, marked) do
    for {no, line, false, _} <- marked, [_, target] <- Regex.scan(@bare_path, line) do
      err(path, no, "путь `#{target}` без префикса `deps/core/`: у потребителя это другой ярус")
    end
  end

  # Соседний ярус адресуется путём от корня потребителя. Файлы яруса ищутся в `dir`: в
  # библиотеке это её же каталог, у потребителя — приехавшая зависимость (нет — не проверяем).
  defp check_tier_links(path, marked, prefix, dir) do
    case dir_files(dir) do
      nil ->
        []

      tier ->
        for {no, line, false, _} <- marked,
            [_, target] <- Regex.scan(tier_link(prefix), line),
            not MapSet.member?(tier, target) do
          err(path, no, "в #{dir} нет `#{target}` — свод обновился?")
        end
    end
  end

  defp tier_link(prefix), do: Regex.compile!("`#{Regex.escape(prefix)}/(\\d\\d-[a-z0-9-]+\\.md)`")

  # ===== карты и доставка =====

  # Карта свода в `00-index.md` и набор файлов совпадают в обе стороны.
  defp check_map(files, dir) do
    index = Path.join(dir, @index)

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

    missing ++ Enum.uniq(extra)
  end

  # У каждого свода, кроме индекса и всегда-загруженных соглашений, есть skill-указатель;
  # у потребителя его тело ведёт на все файлы темы, а не только на локальный.
  defp check_skills(files, tiers) do
    files
    |> Enum.map(&Path.basename/1)
    |> Enum.reject(&(&1 in [@index, @always_on]))
    |> Enum.flat_map(&check_skill(&1, tiers))
  end

  # Карта в точке входа (`AGENTS.md`, на неё симлинк `CLAUDE.md`) и набор файлов совпадают.
  # Пути в `deps/core` из карты вычёркиваются: они адресуют ярусы, а не локальный свод.
  defp check_entry(files) do
    content = @entry |> File.read!() |> String.replace(~r/deps\/core\/\S+/, "")
    actual = Enum.map(files, &Path.basename/1)

    listed =
      ~r/#{@dir}\/(\d\d-[a-z0-9-]+\.md)/ |> Regex.scan(content) |> Enum.map(&Enum.at(&1, 1))

    missing =
      for f <- actual, f not in listed, do: err(@entry, 1, "свод `#{f}` отсутствует в карте")

    extra =
      for f <- listed,
          f not in actual,
          do: err(@entry, 1, "карта ссылается на несуществующий `#{f}`")

    missing ++ Enum.uniq(extra)
  end

  # У соглашений скилла нет ни на одном ярусе — они доставляются импортом в точку входа
  # (`docs/rules/app/00-index.md`, «Файл без скилла»).
  defp check_imports(dirs) do
    content = File.read!(@entry)

    for dir <- dirs,
        File.exists?(Path.join(dir, @always_on)),
        not String.contains?(content, "@#{dir}/#{@always_on}") do
      err(@entry, 1, "нет импорта `@#{dir}/#{@always_on}`: файл без скилла не попадёт в контекст")
    end
  end

  # Точка входа одна: `CLAUDE.md` — симлинк на `AGENTS.md`, иначе карты разойдутся.
  defp check_alias do
    case File.read_link(@alias) do
      {:ok, @entry} -> []
      {:ok, other} -> [err(@alias, 1, "симлинк ведёт на `#{other}`, ожидается `#{@entry}`")]
      {:error, _} -> [err(@alias, 1, "не симлинк на `#{@entry}`")]
    end
  end

  # ---

  defp check_skill(file, tiers) do
    name = file |> String.replace(~r/^\d\d-/, "") |> String.replace_suffix(".md", "")
    path = Path.join([@skills_dir, name, "SKILL.md"])

    if File.exists?(path) do
      content = File.read!(path)

      ([
         {Regex.match?(~r/^name: #{name}$/m, content), "frontmatter `name:` не равен `#{name}`"},
         {Regex.match?(~r/^description: ".{80,}"$/m, content), "нет содержательного `description:`"},
         {String.contains?(content, "`#{@dir}/#{file}`"), "тело не ссылается на `#{@dir}/#{file}`"}
       ] ++ skill_tiers(content, file, tiers))
      |> Enum.reject(&elem(&1, 0))
      |> Enum.map(&err(path, 1, elem(&1, 1)))
    else
      [err(path, 1, "нет skill-указателя на `#{file}` (имя скилла — `#{name}`)")]
    end
  end

  # Ярус требуется, только если он получен и файл этой темы в нём есть.
  defp skill_tiers(content, file, tiers) do
    for dir <- tiers, tier_has?(dir, file) do
      {String.contains?(content, "`#{dir}/#{file}`"), "тело не ссылается на `#{dir}/#{file}`"}
    end
  end

  defp tier_has?(dir, file) do
    case dir_files(dir) do
      nil -> false
      tier -> MapSet.member?(tier, file)
    end
  end

  # ===== общее =====

  defp dir_files(dir) do
    case File.ls(dir) do
      {:ok, files} -> MapSet.new(files)
      {:error, _} -> nil
    end
  end

  defp err(path, line, message), do: "#{path}:#{line}: #{message}"
end

RulesLint.run(System.argv())
