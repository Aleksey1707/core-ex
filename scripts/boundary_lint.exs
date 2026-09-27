# Границы между библиотекой и потребителем. Проверка идёт по AST, а не грепом:
# упоминание вызова в `@moduledoc` — строковый литерал, а не обращение.
#
#   elixir scripts/boundary_lint.exs                      # библиотека (цель `make boundary-check`)
#   elixir scripts/boundary_lint.exs --consumer lib test  # приложение-потребитель
#
# Режим библиотеки проверяет главный инвариант «Core не знает потребителя»
# (`docs/rules/10-architecture.md`), режим потребителя — что DI репозиториев (`Repo` и
# `ReadRepo`) идёт через `Core.Config.repo!/1` (`docs/rules/13-repos.md`, «DI»), а в `lib/` —
# что путь файла равен имени модуля, у контекста есть модуль-оглавление, а `Common` и чужой контекст
# не ссылаются на срезы (`docs/rules/app/10-architecture.md`, «Раскладка»). Норму ввела
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
  @common_slice "common-slice"
  @foreign_slice "foreign-slice"
  @bc_index "bc-index"
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

    root = layout_root(dir, mode)

    files =
      dir
      |> Path.join(sources(mode))
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.map(&parse/1)

    Enum.flat_map(files, &check_file(&1, mode, root)) ++ index_violations(files, root)
  end

  # Путь файла сверяется с именем модуля только в `lib/` потребителя: дерево тестов — не норма линтера.
  defp layout_root(dir, :consumer), do: if(Path.basename(Path.expand(dir)) == "lib", do: dir)
  defp layout_root(_dir, :library), do: nil

  # Потребитель держит DI и в тестах (`19-testing.md`), библиотека — только в `lib/*.ex`.
  defp sources(:library), do: "**/*.ex"
  defp sources(:consumer), do: "**/*.{ex,exs}"

  defp parse(path) do
    source = File.read!(path)
    {ast, comments} = Code.string_to_quoted_with_comments!(source, token_metadata: true)
    %{path: path, ast: ast, markers: markers(ast, comments, String.split(source, "\n"))}
  end

  defp check_file(%{path: path, ast: ast, markers: markers}, mode, root) do
    {_ast, errors} = Macro.prewalk(ast, [], fn node, acc -> {node, acc ++ violations(node, path, mode)} end)

    (errors ++ module_path_violations(ast, path, root) ++ direction_violations(ast, path, root))
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

  # Конвенция Mix: `Mix.Tasks.Foo.Bar` — задача `foo.bar`, файл `mix/tasks/foo.bar.ex`.
  defp module_file("Mix.Tasks." <> task),
    do: "mix/tasks/#{task |> String.split(".") |> Enum.map_join(".", &Macro.underscore/1)}.ex"

  defp module_file(name), do: Macro.underscore(name) <> ".ex"

  defp layout_err(path, line, message), do: violation(path, line, message, @module_path, @layout)

  # ===== потребитель: направления зависимостей контекста =====

  # Контекст — `<Root>.Domain.<BC>`, его части — `Common` и срезы; корень берётся из имени модуля,
  # где стоит ссылка. `Common` не видит срезов своего контекста, чужой контекст виден только через
  # его `Common`. Вне `Domain` (web, подсистемы, точки входа) правил нет. Модуль в корне контекста
  # норма запрещает, поэтому любая часть кроме `Common` считается срезом.
  defp direction_violations(_ast, _path, nil), do: []

  defp direction_violations(ast, path, _root) do
    {_env, refs} = walk(ast, %{module: nil, aliases: %{}})
    Enum.flat_map(refs, fn {from, to, line} -> direction(from, to, line, path) end)
  end

  defp direction(from, to, line, path) do
    case {bc_part(from), bc_part(to)} do
      {{root, bc, :Common}, {root, bc, part}} when part not in [:Common, nil] ->
        [
          violation(
            path,
            line,
            "`Common` контекста `#{bc}` ссылается на `#{module_name(to)}` — срез своего контекста, а не `Common`",
            @common_slice,
            @layout
          )
        ]

      {{root, bc, _part}, {root, other, part}} when other != bc and part not in [:Common, nil] ->
        [
          violation(
            path,
            line,
            "ссылка на `#{module_name(to)}` — срез чужого контекста: контекст `#{other}` виден через `#{other}.Common`",
            @foreign_slice,
            @layout
          )
        ]

      _other ->
        []
    end
  end

  # ---

  defp bc_part([root, :Domain, bc, part | _rest]), do: {root, bc, part}
  defp bc_part([root, :Domain, bc]), do: {root, bc, nil}
  defp bc_part(_module), do: nil

  defp module_name(module), do: Enum.map_join(module, ".", &Atom.to_string/1)

  # Обход с лексическими алиасами: блок передаёт алиас следующим выражениям, прочий узел — только
  # своим детям. Строка `alias` ссылкой не считается: нарушение отмечается там, где модуль зовут.
  defp walk({:__block__, _meta, exprs}, env) do
    {_env, refs} =
      Enum.reduce(exprs, {env, []}, fn expr, {env, refs} ->
        {env, more} = walk(expr, env)
        {env, refs ++ more}
      end)

    {env, refs}
  end

  defp walk({:defmodule, _meta, [{:__aliases__, _, parts}, body]}, env) do
    {module, env} = define_module(parts, env)
    {_env, refs} = walk(body, %{env | module: module})
    {env, refs}
  end

  defp walk({:alias, _meta, [target | opts]}, env), do: {define_aliases(target, List.flatten(opts), env), []}

  defp walk({:require, _meta, [target, opts]}, env) when is_list(opts) do
    {_env, refs} = walk(target, env)
    {if(opts[:as], do: define_aliases(target, opts, env), else: env), refs}
  end

  defp walk({{:., _, [base, :{}]}, meta, children}, env) do
    {env, for(module <- multi_targets(base, children, env), do: {env.module, module, meta[:line]})}
  end

  defp walk({:__aliases__, meta, parts}, env) do
    case expand(parts, env) do
      nil -> {env, []}
      module -> {env, [{env.module, module, meta[:line]}]}
    end
  end

  defp walk({form, _meta, args}, env) when is_list(args), do: {env, children([form | args], env)}
  defp walk({left, right}, env), do: {env, children([left, right], env)}
  defp walk(list, env) when is_list(list), do: {env, children(list, env)}
  defp walk(_node, env), do: {env, []}

  # ---

  defp children(nodes, env), do: Enum.flat_map(nodes, &(&1 |> walk(env) |> elem(1)))

  # Вложенный `defmodule Line` внутри `A` — это `A.Line` даже при алиасе `Line`, и `Line` становится
  # алиасом в `A`; `defmodule Elixir.Line` вложенностью не считается.
  defp define_module([first | _rest] = parts, %{module: parent} = env)
       when is_list(parent) and is_atom(first) and first != :"Elixir" do
    {parent ++ parts, put_in(env.aliases[first], parent ++ [first])}
  end

  defp define_module(parts, env), do: {expand(parts, env), env}

  defp define_aliases({{:., _, [base, :{}]}, _, children}, _opts, env) do
    base
    |> multi_targets(children, env)
    |> Enum.reduce(env, &define_alias(&1, nil, &2))
  end

  defp define_aliases({:__aliases__, _, parts}, opts, env), do: define_alias(expand(parts, env), opts[:as], env)
  defp define_aliases({:__MODULE__, _, _}, opts, env), do: define_alias(env.module, opts[:as], env)
  defp define_aliases(_target, _opts, env), do: env

  defp define_alias(nil, _as, env), do: env
  defp define_alias(module, {:__aliases__, _, [as]}, env), do: put_in(env.aliases[as], module)
  defp define_alias(module, _as, env), do: put_in(env.aliases[List.last(module)], module)

  # `A.{B, C.D}` и `__MODULE__.{B}` — модули `A.B`, `A.C.D` и `<модуль>.B`.
  defp multi_targets(base, children, env) do
    base_parts =
      case base do
        {:__aliases__, _, parts} -> parts
        {:__MODULE__, _, _} -> [base]
        _other -> nil
      end

    if base_parts,
      do: for({:__aliases__, _, parts} <- children, module = expand(base_parts ++ parts, env), do: module),
      else: []
  end

  defp expand(parts, env) do
    module = resolve(parts, env)
    if is_list(module) and Enum.all?(module, &is_atom/1), do: module
  end

  defp resolve([{:__MODULE__, _, _} | rest], %{module: module}) when is_list(module), do: module ++ rest
  defp resolve([:"Elixir" | rest], _env), do: rest
  defp resolve([first | rest], env) when is_atom(first), do: Map.get(env.aliases, first, [first]) ++ rest
  defp resolve(_parts, _env), do: nil

  # ===== потребитель: модуль-оглавление контекста =====

  # Каталог `domain/<bc>/` требует модуль `<Root>.Domain.<BC>`: его ищут среди верхнеуровневых модулей
  # `lib/` по `Macro.underscore`, как и путь файла, — так аббревиатура в имени контекста не даёт ложного
  # нарушения. Содержание не проверяется. Нарушение принадлежит каталогу, а не модулю, поэтому его гасит
  # маркер над любым `defmodule` в файлах контекста.
  defp index_violations(_files, nil), do: []

  defp index_violations(files, root) do
    defined =
      for %{ast: ast} <- files, {name, _line} <- top_modules(ast), into: MapSet.new(), do: Macro.underscore(name)

    root
    |> Path.join("*/domain/*")
    |> Path.wildcard()
    |> Enum.filter(&File.dir?/1)
    |> Enum.sort()
    |> Enum.reject(&MapSet.member?(defined, Path.relative_to(Path.expand(&1), Path.expand(root))))
    |> Enum.reject(&index_allowed?(&1, files))
    |> Enum.map(fn dir ->
      violation(
        dir <> "/",
        0,
        "контекст без модуля-оглавления: его `@moduledoc` — карта контекста, файл — #{dir}.ex",
        @bc_index,
        @layout
      )
    end)
  end

  # ---

  defp index_allowed?(dir, files) do
    prefix = Path.expand(dir) <> "/"

    Enum.any?(files, fn %{path: path, markers: markers} ->
      String.starts_with?(Path.expand(path), prefix) and Enum.any?(markers, &match?({@bc_index, _first, _last}, &1))
    end)
  end

  # ===== исключение: маркер у `defmodule` =====

  # Маркер — строка комментария в блоке прямо над `defmodule`:
  # `# boundary-lint: allow <правило> — DEBT.md, «<раздел>»`. Он гасит нарушения своего правила
  # в строках своего модуля (`bc-index` — во всём каталоге контекста); без ссылки на раздел `DEBT.md`
  # не гасит ничего. Хвостовой комментарий строки кода маркером не считается. Нарушения без правила
  # (главный инвариант, DI) не гасятся.
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

  defp err(path, meta, message, doc), do: violation(path, Keyword.get(meta, :line, 0), message, nil, doc)

  # `rule` — имя правила для маркера (`nil` — маркером не гасится), `doc` — норма свода.
  defp violation(path, line, message, rule, doc),
    do: %{line: line, text: "#{path}:#{line}: #{message}", rule: rule, doc: doc}
end

BoundaryLint.run(System.argv())
