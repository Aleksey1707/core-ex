# Границы между библиотекой и потребителем. Проверка идёт по AST, а не грепом:
# упоминание вызова в `@moduledoc` — строковый литерал, а не обращение.
#
#   elixir scripts/boundary_lint.exs                      # библиотека (цель `make boundary-check`)
#   elixir scripts/boundary_lint.exs --consumer lib test  # приложение-потребитель
#
# Режим библиотеки проверяет главный инвариант «Core не знает потребителя»
# (`docs/rules/10-architecture.md`), режим потребителя — что DI репозиториев (`Repo` и
# `ReadRepo`) идёт через `Core.Config.repo!/1` (`docs/rules/13-repos.md`, «DI»), а в `lib/` —
# что путь файла равен имени модуля, корень границы контекста — его модуль-оглавление с
# `use Boundary`, а `Common` и срезов на уровне контекста нет (`docs/rules/app/10-architecture.md`,
# «Раскладка»), проекция лежит в каталоге read-модели (`docs/rules/app/13-repos.md`), а корень web
# состоит из поверхностей и модулей своей таблицы (`docs/rules/app/15-web-api.md`). Направления
# между контекстами держит Boundary при сборке, а не линтер. Норму ввела библиотека, поэтому
# инструмент живёт здесь: потребитель зовёт скрипт из `deps/core/scripts/`, и путь правил в его
# сообщениях — от корня потребителя.

defmodule BoundaryLint do
  @moduledoc false

  @library_dir "lib"
  @consumer_dirs ["lib"]
  @config "lib/core/config.ex"
  @architecture "docs/rules/10-architecture.md"
  @repos "deps/core/docs/rules/13-repos.md"
  @layout "deps/core/docs/rules/app/10-architecture.md"
  @module_path "module-path"
  @bc_index "bc-index"
  @bc_root "bc-root"
  @projection_layout "projection-layout"
  @repos_layout "deps/core/docs/rules/app/13-repos.md"
  @web_root "web-root"
  @web_layout "deps/core/docs/rules/app/15-web-api.md"
  @marker ~r/^#\s*boundary-lint:\s*allow\s+(\S+)\s.*(?<![\w.])DEBT\.md,\s*«[^»]+»/u
  @env_funs ~w(get_env fetch_env fetch_env! compile_env compile_env!)a
  @compile_env_funs ~w(compile_env compile_env!)a
  @own_apps ~w(core argon2_elixir)a
  @repo_keys ~w(Repo ReadRepo)a
  @web_parts ~w(Endpoint Router Telemetry ErrorJSON FallbackController ErrorMapper Accepted Response
                Schemas Presenters Plugs Params)

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

    known = known(files, root)
    Enum.flat_map(files, &check_file(&1, mode, root, known)) ++ index_violations(files, root)
  end

  # Путь файла сверяется с именем модуля только в `lib/` потребителя: дерево тестов — не норма линтера.
  defp layout_root(dir, :consumer), do: if(Path.basename(Path.expand(dir)) == "lib", do: dir)
  defp layout_root(_dir, :library), do: nil

  # Потребитель держит DI и в тестах (`19-testing.md`), библиотека — только в `lib/*.ex`.
  defp sources(:library), do: "**/*.ex"
  defp sources(:consumer), do: "**/*.{ex,exs}"

  defp parse(path) do
    source = File.read!(path)

    case Code.string_to_quoted_with_comments(source, token_metadata: true, file: path) do
      {:ok, ast, comments} ->
        %{path: path, ast: ast, markers: markers(ast, comments, String.split(source, "\n"))}

      {:error, {location, message, token}} ->
        IO.puts(:stderr, "boundary-check: #{path}:#{location[:line]}: не разобран: #{inspect(message)}#{token}")
        System.halt(2)
    end
  end

  defp check_file(%{path: path, ast: ast, markers: markers}, mode, root, known) do
    as_aliases = as_aliases(ast)

    {_ast, errors} =
      Macro.prewalk(ast, [], fn node, acc -> {node, acc ++ violations(node, path, mode, as_aliases)} end)

    (errors ++
       module_path_violations(ast, path, root) ++
       bc_root_violations(path, known) ++
       web_root_violations(ast, path, known) ++ projection_violations(ast, path, root))
    |> Enum.reject(&allowed?(&1, markers))
    |> Enum.uniq_by(&{&1.line, &1.text})
    |> Enum.sort_by(& &1.line)
  end

  # Сведения, которым нужны все файлы: части контекста до вертикали, поверхности web, `ApiSpec` на
  # уровне поверхности, корни приложения и имена всех модулей.
  defp known(_files, nil),
    do: %{
      bc_anchors: %{},
      surfaces: MapSet.new(),
      deep_specs: %{},
      roots: MapSet.new(),
      names: MapSet.new(),
      web_anchors: %{}
    }

  defp known(files, _root) do
    all = for %{ast: ast, markers: markers} <- files, module <- modules(ast), do: {module, markers}
    names = for {%{name: name}, _markers} <- all, into: MapSet.new(), do: name

    placed =
      for %{path: path, ast: ast, markers: markers} <- files,
          module <- modules(ast),
          do: Map.merge(module, %{path: path, markers: markers})

    known = %{
      bc_anchors: bc_anchors(placed, names),
      surfaces:
        for(
          {%{name: name}, _} <- all,
          [web, surface, version, "ApiSpec"] <- [String.split(name, ".")],
          Regex.match?(~r/^V\d+$/, version),
          into: MapSet.new(),
          do: {web, surface}
        ),
      deep_specs: deep_specs(all),
      roots:
        for(
          {%{name: name}, _} <- all,
          [first | _] <- [String.split(name, ".")],
          not String.ends_with?(first, "Web"),
          into: MapSet.new(),
          do: first
        ),
      names: names
    }

    Map.put(known, :web_anchors, web_anchors(placed, known))
  end

  # ---

  # Нарушение `web-root` — одно на namespace `<Web>.<X>`: правка у них одна. Оно ставится на модуль с
  # `ApiSpec` не на месте, если он есть, иначе на первый по пути и строке; там же — число прочих модулей.
  defp web_anchors(placed, known) do
    placed
    |> Enum.filter(&web_offender?(&1.name, known))
    |> Enum.group_by(&(&1.name |> String.split(".") |> Enum.take(2) |> List.to_tuple()))
    |> Map.new(fn {key, modules} ->
      spec = key |> Tuple.to_list() |> Enum.join(".") |> Kernel.<>(".ApiSpec")
      anchor = Enum.find(modules, &(&1.name == spec)) || Enum.min_by(modules, &{&1.path, &1.line})
      {key, %{path: anchor.path, line: anchor.line, others: length(modules) - 1}}
    end)
  end

  defp web_offender?(name, known) do
    case String.split(name, ".") do
      [web, part | _rest] ->
        String.ends_with?(web, "Web") and MapSet.member?(known.roots, String.replace_suffix(web, "Web", "")) and
          part not in @web_parts and not MapSet.member?(known.surfaces, {web, part})

      _other ->
        false
    end
  end

  # `ApiSpec` на уровне поверхности (`<Web>.<Api>.ApiSpec`) — подсказка опустить его на версию; прочий
  # `ApiSpec` не на месте (`Helper.Deep.ApiSpec`) поверхности не делает и подсказки нет.
  defp deep_specs(all) do
    for {%{name: name}, _markers} <- all,
        [web, surface, "ApiSpec"] <- [String.split(name, ".")],
        into: %{},
        do: {{web, surface}, name}
  end

  # ===== библиотека: `Core` не знает потребителя =====

  # Сборочный контекст потребителя: у библиотеки его нет.
  defp violations({:__aliases__, meta, [:Mix, :Project]}, path, :library, _as_aliases) do
    [err(path, meta, "`Mix.Project` — сборочный контекст потребителя", @architecture)]
  end

  # Чтение app-env по литеральному имени приложения: чужое имя в библиотеке не зашивается.
  defp violations(
         {{:., _, [{:__aliases__, _, [:Application]}, fun]}, meta, [app | _]},
         path,
         :library,
         _as_aliases
       )
       when fun in @env_funs and is_atom(app) do
    if app in @own_apps,
      do: [],
      else: [err(path, meta, "`Application.#{fun}` читает #{inspect(app)} — чужой app-env", @architecture)]
  end

  # Имя приложения-потребителя приходит переменной, поэтому правило выше его не видит:
  # единственный источник этого имени — `Core.Config.otp_app/0`, и звать его вправе
  # только сам `Core.Config`.
  defp violations({{:., _, [{:__aliases__, _, mods}, :otp_app]}, meta, []}, path, :library, _as_aliases) do
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
         :consumer,
         as_aliases
       )
       when fun in @compile_env_funs do
    message =
      "`Application.#{fun}` на #{Macro.to_string(key)}: реализация резолвится `Core.Config.repo!/1`"

    if List.last(resolve_as(mods, as_aliases)) in @repo_keys,
      do: [err(path, meta, message, @repos)],
      else: []
  end

  defp violations(_node, _path, _mode, _as_aliases), do: []

  # `alias A.B.Repo, as: OrderRepo` — ключ `OrderRepo` в `compile_env` разрешается в `A.B.Repo`.
  # Карта на файл, а не лексическая: имя `as:`, объявленное в файле с разными целями, не разрешается.
  defp as_aliases(ast) do
    {_ast, found} =
      Macro.prewalk(ast, %{}, fn
        {:alias, _meta, [{:__aliases__, _, target}, opts]} = node, acc when is_list(opts) ->
          case opts[:as] do
            {:__aliases__, _, [as]} -> {node, Map.update(acc, as, [target], &Enum.uniq([target | &1]))}
            _other -> {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    for {as, [target]} <- found, into: %{}, do: {as, target}
  end

  defp resolve_as([first | rest] = mods, as_aliases) do
    case as_aliases do
      %{^first => target} -> target ++ rest
      %{} -> mods
    end
  end

  # ===== потребитель: путь файла = имя модуля =====

  # Сверяется `Macro.underscore` имени с путём, а не `camelize` пути с именем: иначе аббревиатура
  # (`AppA` в `app_a/`, `HTTPClient` в `http_client.ex`) дала бы ложное нарушение. Вложенные модули
  # следуют за родителем и не сверяются; одноимённые определения под `if` — один модуль.
  defp module_path_violations(_ast, _path, nil), do: []

  defp module_path_violations(ast, path, root) do
    top =
      ast
      |> top_modules()
      |> Enum.uniq_by(fn {name, _line} -> name end)

    top_names = MapSet.new(top, fn {name, _line} -> name end)

    Enum.flat_map(Enum.with_index(top), fn {{name, line}, index} -> module_path(name, line, index, path, root) end) ++
      nested_member_violations(ast, top_names, path, root)
  end

  # Событие и команда — свой файл, даже вложенные в семейство `<Aggregate>.Event` / `<Aggregate>.Cmd`
  # (`13-repos.md`, «Событие и команда»): вложенный модуль следует за родителем, но у члена семейства
  # родитель — семейство, а не он сам.
  # Член семейства — `<Root>.Domain.<BC>.<Aggregate>.{Event,Cmd}.<Name>`: вложенный Prim агрегата с именем
  # `Event` (`<BC>.Event.ID`), модуль вне `Domain` и кодек семейства правилом не считаются.
  defp nested_member_violations(ast, top_names, path, root) do
    for %{name: name, line: line} <- modules(ast),
        not MapSet.member?(top_names, name),
        [_root, "Domain", _bc, _aggregate, family, member] <- [String.split(name, ".")],
        family in ["Event", "Cmd"] and member != "Codec",
        do:
          layout_err(
            path,
            line,
            "`#{name}` вложен в семейство: событие и команда — свой файл, #{Path.join(root, module_file(name))}"
          )
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

  # ===== потребитель: модуль-оглавление — корень границы контекста =====

  # Каталог `domain/<bc>/` требует модуль `<Root>.Domain.<BC>` с `use Boundary`: контекст — граница
  # верхнего уровня, и её корень — оглавление. Модуль ищут среди верхнеуровневых модулей `lib/` по
  # `Macro.underscore`, как и путь файла, — так аббревиатура в имени контекста не даёт ложного нарушения;
  # `use` разрешается через `alias`, опции границы и `@moduledoc` не проверяются. Нарушение принадлежит
  # каталогу, а не модулю, поэтому его гасит маркер над любым `defmodule` в файлах контекста и в оглавлении.
  defp index_violations(_files, nil), do: []

  defp index_violations(files, root) do
    indexes =
      for %{path: path, ast: ast} <- files,
          {name, _line} <- top_modules(ast),
          %{name: ^name} = module <- modules(ast),
          into: %{},
          do: {Macro.underscore(name), Map.put(module, :path, path)}

    root
    |> Path.join("*/domain/*")
    |> Path.wildcard()
    |> Enum.filter(&File.dir?/1)
    |> Enum.sort()
    |> Enum.reject(&index_allowed?(&1, files))
    |> Enum.flat_map(&index_violation(&1, indexes[Path.relative_to(Path.expand(&1), Path.expand(root))]))
  end

  # ---

  defp index_allowed?(dir, files) do
    prefix = Path.expand(dir) <> "/"
    index = Path.expand(dir) <> ".ex"

    Enum.any?(files, fn %{path: path, markers: markers} ->
      (String.starts_with?(Path.expand(path), prefix) or Path.expand(path) == index) and
        Enum.any?(markers, &match?({@bc_index, _first, _last}, &1))
    end)
  end

  defp index_violation(dir, nil) do
    [
      violation(
        dir <> "/",
        0,
        "контекст без модуля-оглавления: оглавление — корень границы контекста (`use Boundary` с `deps` и " <>
          "`exports`), его `@moduledoc` — карта контекста, файл — #{dir}.ex; контекст без агрегатов — не " <>
          "контекст, а подсистема",
        @bc_index,
        @layout
      )
    ]
  end

  defp index_violation(_dir, %{uses: uses} = index) do
    if [:Boundary] in uses,
      do: [],
      else: [
        violation(
          index.path,
          index.line,
          "`#{index.name}` — оглавление без `use Boundary`: контекст — граница верхнего уровня, её корень — " <>
            "оглавление с `deps` и `exports`",
          @bc_index,
          @layout
        )
      ]
  end

  # ===== потребитель: `Common` и срезы на уровне контекста =====

  # Раскладка — вертикаль по агрегату: модули контекста лежат в каталогах агрегатов и в каталогах уровня
  # контекста по виду (`Values`, `Errors`, read-модель и операция по назначению, `Reactions`). Раскладку до
  # неё выдают две части: `<BC>.Common` целиком и срез — namespace `<BC>.<X>.Usecases` с usecases по
  # сценарию, который сам модулем не объявлен (общий модуль чтения `<BC>.<Aggregate>.Usecases` — модуль, и
  # под ним MAY лежать свои). Нарушение — одно на часть: правка у неё одна, перенос. Оно ставится на первый
  # модуль части по пути и строке, там же — число прочих; маркер над любым модулем части его гасит.
  defp bc_anchors(placed, names) do
    placed
    |> Enum.flat_map(fn module -> for part <- [bc_part(module.parts, names)], part, do: {part, module} end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.reject(fn {_part, modules} -> Enum.any?(modules, &part_allowed?/1) end)
    |> Map.new(fn {part, modules} ->
      anchor = Enum.min_by(modules, &{&1.path, &1.line})
      {part, %{path: anchor.path, line: anchor.line, others: length(modules) - 1}}
    end)
  end

  defp bc_root_violations(path, known) do
    for {{root, bc, part}, %{path: ^path, line: line, others: others}} <- known.bc_anchors,
        do: violation(path, line, bc_root_message(root, bc, part) <> others(others), @bc_root, @layout)
  end

  # ---

  defp bc_part([root, :Domain, bc, :Common | _rest], _names), do: {root, bc, :Common}

  defp bc_part([root, :Domain, bc, slice, :Usecases, _usecase | _rest], names) do
    if MapSet.member?(names, module_name([root, :Domain, bc, slice, :Usecases])),
      do: nil,
      else: {root, bc, slice}
  end

  defp bc_part(_parts, _names), do: nil

  defp part_allowed?(module), do: allowed?(%{rule: @bc_root, line: module.line}, module.markers)

  defp bc_root_message(root, bc, :Common) do
    context = "#{root}.Domain.#{bc}"

    "`#{context}.Common` — общая часть контекста: раскладка до вертикали, `Common` нет. Всё об агрегате — " <>
      "в его каталоге `#{context}.<Aggregate>`, значение без владельца — в `#{context}.Values`, read-модель " <>
      "не по агрегату — в каталоге по назначению"
  end

  defp bc_root_message(root, bc, slice) do
    context = "#{root}.Domain.#{bc}"

    "`#{context}.#{slice}` — срез на уровне контекста: раскладка до вертикали, срезов нет. Usecases актора — " <>
      "модуль `#{context}.<Aggregate>.#{slice}.Usecases` в каталоге агрегата, операция над равноправными " <>
      "агрегатами — `#{context}.<Operation>.#{slice}.Usecases`"
  end

  # ===== потребитель: проекция в каталоге read-модели =====

  # Проекция — ровно `<Root>.Domain.<BC>.<ReadModel>.Projection` (или `ProjectionV<N>` на время перехода):
  # read-модель агрегата лежит в его каталоге, не по агрегату — в каталоге по назначению, а у актора своей
  # проекции нет — таблица и проекция общие. Модуль с `use Core.Es.Projection` в другом месте — проекция
  # контекста или модуль под read-моделью. `use` разрешается через `alias`, код в `quote` макроса-обёртки
  # не проверяется. Отдельный модуль записи — `*.Projector` под `ReadRepo`: слово `Projector` вне `ReadRepo`
  # бывает доменным.
  defp projection_violations(_ast, _path, nil), do: []

  defp projection_violations(ast, path, _root) do
    for %{parts: parts, name: name, line: line, uses: uses} <- modules(ast),
        message <- projection_message(Enum.map(parts, &Atom.to_string/1), name, [:Core, :Es, :Projection] in uses),
        do: violation(path, line, message, @projection_layout, @repos_layout)
  end

  # ---

  defp projection_message(parts, name, uses?) do
    cond do
      List.last(parts) == "Projector" and "ReadRepo" in parts ->
        ["`#{name}` — отдельный модуль записи проекции: таблицы пишет сама `<ReadModel>.Projection`"]

      uses? and not read_model_projection?(parts) ->
        [
          "`#{name}` — проекция вне каталога read-модели: ожидается `<BC>.<ReadModel>.Projection` — в каталоге " <>
            "агрегата или read-модели по назначению"
        ]

      true ->
        []
    end
  end

  defp read_model_projection?([_root, "Domain", _bc, _read_model, projection]),
    do: Regex.match?(~r/^Projection(V\d+)?$/, projection)

  defp read_model_projection?(_parts), do: false

  # ===== потребитель: корень web =====

  # Второй сегмент модуля `<Root>Web.<X>` — из закрытого списка корня web либо поверхность. Поверхность —
  # namespace хотя бы с одним `<Root>Web.<X>.V<N>.ApiSpec` (вложенным или своим файлом): спецификация — на
  # версию. `ApiSpec` в другом месте поверхностью не делает — подсказка называет найденный. Корень web — только
  # `<Root>Web` при корне `<Root>` модулей `lib/`: чужой `OtherWeb` проверяется как подсистема.
  defp web_root_violations(_ast, path, known) do
    for {{web, part}, %{path: ^path, line: line, others: others}} <- known.web_anchors,
        do:
          violation(path, line, web_root_message(web, part, known.deep_specs) <> others(others), @web_root, @web_layout)
  end

  # ---

  defp web_root_message(web, part, deep_specs) do
    base =
      "`#{web}.#{part}` — не часть корня web: поверхность (`#{web}.<Api>` с `<Api>.V<N>.ApiSpec`) или " <>
        Enum.join(@web_parts, ", ")

    case deep_specs do
      _root_spec when part == "ApiSpec" ->
        base <> "; `ApiSpec` — у версии поверхности: `#{web}.<Api>.<Version>.ApiSpec`"

      %{{^web, ^part} => spec} ->
        base <> "; `#{spec}` — спецификация на версию: `#{web}.#{part}.<Version>.ApiSpec`"

      %{} ->
        base <>
          "; модуль одного ресурса — в `#{web}.<Api>.<Version>.<Resource>.<Роль>`, в корне — только общее " <>
          "для поверхностей"
    end
  end

  # ===== модули файла =====

  # Все модули файла с полными именами — верхнеуровневые, вложенные и `defprotocol` — вместе с `use`,
  # разрешёнными через `alias` тела. Код внутри `quote` принадлежит модулю, куда он инжектится, и не
  # обходится.
  defp modules(ast) do
    {_env, found} = collect_modules(ast, %{module: nil, aliases: %{}})
    found
  end

  # ---

  defp collect_modules({:__block__, _meta, exprs}, env) do
    Enum.reduce(exprs, {env, []}, fn expr, {env, found} ->
      {env, more} = collect_modules(expr, env)
      {env, found ++ more}
    end)
  end

  defp collect_modules({kind, meta, [{:__aliases__, _, parts}, body]}, env) when kind in [:defmodule, :defprotocol] do
    case define_module(parts, env) do
      {nil, env} ->
        {env, []}

      {module, env} ->
        inner = %{env | module: module}
        {_env, nested} = collect_modules(body, inner)
        {_env, uses} = use_targets(body, inner)
        {env, [%{parts: module, name: module_name(module), line: meta[:line], uses: uses} | nested]}
    end
  end

  defp collect_modules({:alias, _meta, [target | opts]}, env), do: {define_aliases(target, List.flatten(opts), env), []}
  defp collect_modules({:quote, _meta, _args}, env), do: {env, []}
  defp collect_modules({form, _meta, args}, env) when is_list(args), do: {env, collected([form | args], env)}
  defp collect_modules({left, right}, env), do: {env, collected([left, right], env)}
  defp collect_modules(list, env) when is_list(list), do: {env, collected(list, env)}
  defp collect_modules(_node, env), do: {env, []}

  defp collected(nodes, env), do: Enum.flat_map(nodes, &(&1 |> collect_modules(env) |> elem(1)))

  defp use_targets({:__block__, _meta, exprs}, env) do
    Enum.reduce(exprs, {env, []}, fn expr, {env, found} ->
      {env, more} = use_targets(expr, env)
      {env, found ++ more}
    end)
  end

  defp use_targets({:use, _meta, [{:__aliases__, _, parts} | _opts]}, env) do
    case expand(parts, env) do
      nil -> {env, []}
      module -> {env, [module]}
    end
  end

  defp use_targets({:alias, _meta, [target | opts]}, env), do: {define_aliases(target, List.flatten(opts), env), []}
  defp use_targets({kind, _meta, _args}, env) when kind in [:defmodule, :defprotocol, :quote], do: {env, []}
  defp use_targets({form, _meta, args}, env) when is_list(args), do: {env, used([form | args], env)}
  defp use_targets({left, right}, env), do: {env, used([left, right], env)}
  defp use_targets(list, env) when is_list(list), do: {env, used(list, env)}
  defp use_targets(_node, env), do: {env, []}

  defp used(nodes, env), do: Enum.flat_map(nodes, &(&1 |> use_targets(env) |> elem(1)))

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
        {kind, meta, [_name, _body]} = node, acc when kind in [:defmodule, :defprotocol] ->
          {node, acc ++ module_markers(meta, last_line(node), by_line)}

        node, acc ->
          {node, acc}
      end)

    markers
  end

  defp allowed?(%{rule: rule, line: line}, markers),
    do: Enum.any?(markers, fn {allowed, first, last} -> allowed == rule and line in first..last end)

  # ---

  defp module_markers(meta, last, by_line) do
    first = meta[:line]

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

  # У `defmodule … do … end` последняя строка — `end`, у формы `defmodule X, do: …` — самая дальняя строка
  # тела.
  defp last_line({_kind, meta, _args} = node) do
    {_node, last} =
      Macro.prewalk(node, meta[:line], fn
        {_form, node_meta, _args} = child, acc when is_list(node_meta) ->
          {child, Enum.max([acc, node_meta[:line] || acc, get_in(node_meta, [:end, :line]) || acc])}

        child, acc ->
          {child, acc}
      end)

    last
  end

  # ===== общее =====

  defp module_name(module), do: Enum.map_join(module, ".", &Atom.to_string/1)

  defp others(0), do: ""
  defp others(count), do: "; прочих модулей namespace с тем же нарушением: #{count}, правка одна"

  defp top_modules({kind, meta, [{:__aliases__, _, parts}, _body]}) when kind in [:defmodule, :defprotocol] do
    if Enum.all?(parts, &is_atom/1),
      do: [{Enum.map_join(parts, ".", &Atom.to_string/1), meta[:line]}],
      else: []
  end

  defp top_modules({kind, _meta, _args}) when kind in [:defmodule, :defprotocol], do: []
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
