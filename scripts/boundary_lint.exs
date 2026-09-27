# Границы между библиотекой и потребителем. Проверка идёт по AST, а не грепом:
# упоминание вызова в `@moduledoc` — строковый литерал, а не обращение.
#
#   elixir scripts/boundary_lint.exs                      # библиотека (цель `make boundary-check`)
#   elixir scripts/boundary_lint.exs --consumer lib test  # приложение-потребитель
#
# Режим библиотеки проверяет главный инвариант «Core не знает потребителя»
# (`docs/rules/10-architecture.md`), режим потребителя — что DI репозиториев (`Repo` и
# `ReadRepo`) идёт через `Core.Config.repo!/1` (`docs/rules/13-repos.md`, «DI»), а в `lib/` —
# что путь файла равен имени модуля (`docs/rules/app/10-architecture.md`, «Раскладка»). Норму ввела
# библиотека, поэтому инструмент живёт здесь: потребитель зовёт скрипт из `deps/core/scripts/`,
# и путь правил в его сообщениях — от корня потребителя.

defmodule BoundaryLint do
  @moduledoc false

  @library_dir "lib"
  @consumer_dirs ["lib"]
  @config "lib/core/config.ex"
  @architecture "docs/rules/10-architecture.md"
  @repos "deps/core/docs/rules/13-repos.md"
  @layout "deps/core/docs/rules/app/10-architecture.md"
  @module_path "module-path"
  @marker ~r/^#\s*boundary-lint:\s*allow\s+(\S+)\s.*DEBT\.md,\s*«[^»]+»/u
  @env_funs ~w(get_env fetch_env fetch_env! compile_env compile_env!)a
  @compile_env_funs ~w(compile_env compile_env!)a
  @own_apps ~w(core argon2_elixir)a
  @repo_keys ~w(Repo ReadRepo)a

  def run(["--consumer" | dirs]) do
    check(:consumer, if(dirs == [], do: @consumer_dirs, else: dirs))
  end

  def run([]), do: check(:library, [@library_dir])

  def run(argv) do
    IO.puts(:stderr, "boundary-check: неизвестные аргументы #{inspect(argv)}")
    IO.puts(:stderr, "  elixir scripts/boundary_lint.exs [--consumer [<каталог> ...]]")
    System.halt(2)
  end

  defp check(mode, dirs) do
    errors = Enum.flat_map(dirs, &check_dir(&1, mode))

    if errors == [] do
      IO.puts("boundary-check (#{mode}): #{Enum.join(dirs, ", ")} — нарушений нет")
    else
      abort(errors)
    end
  end

  defp abort(errors) do
    rules = errors |> Enum.map(& &1.doc) |> Enum.uniq() |> Enum.join(", ")

    Enum.each(errors, &IO.puts(:stderr, &1.text))
    IO.puts(:stderr, "\nboundary-check: нарушений — #{length(errors)}; правила — #{rules}")
    System.halt(1)
  end

  defp check_dir(dir, mode) do
    unless File.dir?(dir) do
      IO.puts(:stderr, "boundary-check: каталог #{dir} не найден")
      System.halt(2)
    end

    dir
    |> Path.join(sources(mode))
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.flat_map(&check_file(&1, mode, layout_root(dir, mode)))
  end

  # Путь файла сверяется с именем модуля только в `lib/` потребителя: дерево тестов — не норма линтера.
  defp layout_root(dir, :consumer), do: if(Path.basename(Path.expand(dir)) == "lib", do: dir)
  defp layout_root(_dir, :library), do: nil

  # Потребитель держит DI и в тестах (`19-testing.md`), библиотека — только в `lib/*.ex`.
  defp sources(:library), do: "**/*.ex"
  defp sources(:consumer), do: "**/*.{ex,exs}"

  defp check_file(path, mode, root) do
    source = File.read!(path)
    {ast, comments} = Code.string_to_quoted_with_comments!(source, token_metadata: true)
    {_ast, errors} = Macro.prewalk(ast, [], fn node, acc -> {node, acc ++ violations(node, path, mode)} end)
    markers = markers(ast, comments, String.split(source, "\n"))

    (errors ++ module_path_violations(ast, path, root))
    |> Enum.reject(&allowed?(&1, markers))
    |> Enum.sort_by(& &1.line)
  end

  # ===== библиотека: `Core` не знает потребителя =====

  # Сборочный контекст потребителя: у библиотеки его нет.
  defp violations({:__aliases__, meta, [:Mix, :Project]}, path, :library) do
    [err(path, meta, "`Mix.Project` — сборочный контекст потребителя", @architecture)]
  end

  # Чтение app-env по литеральному имени приложения: чужое имя в библиотеке не зашивается.
  defp violations(
         {{:., _, [{:__aliases__, _, [:Application]}, fun]}, meta, [app | _]},
         path,
         :library
       )
       when fun in @env_funs and is_atom(app) do
    if app in @own_apps,
      do: [],
      else: [err(path, meta, "`Application.#{fun}` читает #{inspect(app)} — чужой app-env", @architecture)]
  end

  # Имя приложения-потребителя приходит переменной, поэтому правило выше его не видит:
  # единственный источник этого имени — `Core.Config.otp_app/0`, и звать его вправе
  # только сам `Core.Config`.
  defp violations({{:., _, [{:__aliases__, _, mods}, :otp_app]}, meta, []}, path, :library) do
    if List.last(mods) == :Config and path != @config,
      do: [err(path, meta, "`otp_app/0` вне `#{@config}`: app-env потребителя читается там", @architecture)],
      else: []
  end

  # ===== потребитель: DI репозиториев — через `Core.Config.repo!/1` =====

  # Ключ-репозиторий в `compile_env` — это связывание «behaviour → реализация» руками.
  # Прочие ключи-модули (`MyApp.Endpoint`, `MyApp.Mailer`, …) — обычная конфигурация, не DI.
  defp violations(
         {{:., _, [{:__aliases__, _, [:Application]}, fun]}, meta, [_app, {:__aliases__, _, mods} = key | _]},
         path,
         :consumer
       )
       when fun in @compile_env_funs do
    message =
      "`Application.#{fun}` на #{Macro.to_string(key)}: реализация резолвится `Core.Config.repo!/1`"

    if List.last(mods) in @repo_keys,
      do: [err(path, meta, message, @repos)],
      else: []
  end

  defp violations(_node, _path, _mode), do: []

  # ===== потребитель: путь файла = имя модуля =====

  # Сверяется `Macro.underscore` имени с путём, а не `camelize` пути с именем: иначе аббревиатура
  # (`AppA` в `app_a/`, `HTTPClient` в `http_client.ex`) дала бы ложное нарушение. Вложенные модули
  # следуют за родителем и не сверяются; одноимённые определения под `if` — один модуль.
  defp module_path_violations(_ast, _path, nil), do: []

  defp module_path_violations(ast, path, root) do
    ast
    |> top_modules()
    |> Enum.uniq_by(fn {name, _line} -> name end)
    |> Enum.with_index()
    |> Enum.flat_map(fn {{name, line}, index} -> module_path(name, line, index, path, root) end)
  end

  defp module_path(name, line, index, path, root) do
    expected = Path.join(root, module_file(name))

    cond do
      index > 0 ->
        [layout_err(path, line, "ещё один верхнеуровневый модуль `#{name}` в файле: его файл — #{expected}")]

      Path.expand(Path.rootname(path)) != Path.expand(Path.rootname(expected)) ->
        [layout_err(path, line, "модуль `#{name}` не по пути: путь файла = имя модуля, ожидается #{expected}")]

      true ->
        []
    end
  end

  # ---

  defp top_modules({:defmodule, meta, [{:__aliases__, _, parts}, _body]}) do
    if Enum.all?(parts, &is_atom/1),
      do: [{Enum.map_join(parts, ".", &Atom.to_string/1), meta[:line]}],
      else: []
  end

  defp top_modules({:defmodule, _meta, _args}), do: []
  defp top_modules({left, _meta, args}) when is_list(args), do: top_modules(left) ++ top_modules(args)
  defp top_modules({left, right}), do: top_modules(left) ++ top_modules(right)
  defp top_modules(list) when is_list(list), do: Enum.flat_map(list, &top_modules/1)
  defp top_modules(_node), do: []

  # Конвенция Mix: `Mix.Tasks.Foo.Bar` — задача `foo.bar`, файл `mix/tasks/foo.bar.ex`.
  defp module_file("Mix.Tasks." <> task),
    do: "mix/tasks/#{task |> String.split(".") |> Enum.map_join(".", &Macro.underscore/1)}.ex"

  defp module_file(name), do: Macro.underscore(name) <> ".ex"

  defp layout_err(path, line, message), do: violation(path, line, message, @module_path, @layout)

  # ===== исключение: маркер у `defmodule` =====

  # Маркер — строка комментария в блоке прямо над `defmodule`:
  # `# boundary-lint: allow <правило> — DEBT.md, «<раздел>»`. Он гасит нарушения своего правила
  # в строках своего модуля; без ссылки на раздел `DEBT.md` не гасит ничего. Хвостовой комментарий
  # строки кода маркером не считается. Нарушения без правила (главный инвариант, DI) не гасятся.
  defp markers(ast, comments, lines) do
    by_line =
      for %{line: line, text: text} <- comments,
          lines |> Enum.at(line - 1) |> String.trim_leading() |> String.starts_with?("#"),
          into: %{},
          do: {line, text}

    {_ast, markers} =
      Macro.prewalk(ast, [], fn
        {:defmodule, meta, [_name, _body]} = node, acc -> {node, acc ++ module_markers(meta, by_line)}
        node, acc -> {node, acc}
      end)

    markers
  end

  defp allowed?(%{rule: rule, line: line}, markers),
    do: Enum.any?(markers, fn {allowed, first, last} -> allowed == rule and line in first..last end)

  # ---

  defp module_markers(meta, by_line) do
    first = meta[:line]
    last = get_in(meta, [:end, :line]) || first

    (first - 1)
    |> Stream.iterate(&(&1 - 1))
    |> Stream.map(&Map.get(by_line, &1))
    |> Enum.take_while(& &1)
    |> Enum.flat_map(fn text ->
      case Regex.run(@marker, text) do
        [_text, rule] -> [{rule, first, last}]
        nil -> []
      end
    end)
  end

  # ===== общее =====

  defp err(path, meta, message, doc), do: violation(path, Keyword.get(meta, :line, 0), message, nil, doc)

  # `rule` — имя правила для маркера (`nil` — маркером не гасится), `doc` — норма свода.
  defp violation(path, line, message, rule, doc),
    do: %{line: line, text: "#{path}:#{line}: #{message}", rule: rule, doc: doc}
end

BoundaryLint.run(System.argv())
