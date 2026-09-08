# Границы между библиотекой и потребителем. Проверка идёт по AST, а не грепом:
# упоминание вызова в `@moduledoc` — строковый литерал, а не обращение.
#
#   elixir scripts/boundary_lint.exs                      # библиотека (цель `make boundary-check`)
#   elixir scripts/boundary_lint.exs --consumer lib test  # приложение-потребитель
#
# Режим библиотеки проверяет главный инвариант «Core не знает потребителя»
# (`docs/rules/10-architecture.md`), режим потребителя — что DI репозиториев идёт через
# `Core.Config.repo!/1` (`docs/rules/13-repos.md`, «DI»). Норму ввела библиотека, поэтому
# инструмент живёт здесь: потребитель зовёт скрипт из `deps/core/scripts/`.

defmodule BoundaryLint do
  @moduledoc false

  @library_dir "lib"
  @consumer_dirs ["lib"]
  @config "lib/core/config.ex"
  @architecture "docs/rules/10-architecture.md"
  @repos "docs/rules/13-repos.md"
  @env_funs ~w(get_env fetch_env fetch_env! compile_env compile_env!)a
  @compile_env_funs ~w(compile_env compile_env!)a
  @own_apps ~w(core argon2_elixir)a

  def run(["--consumer" | dirs]) do
    check(:consumer, if(dirs == [], do: @consumer_dirs, else: dirs), @repos)
  end

  def run([]), do: check(:library, [@library_dir], @architecture)

  def run(argv) do
    IO.puts(:stderr, "boundary-check: неизвестные аргументы #{inspect(argv)}")
    IO.puts(:stderr, "  elixir scripts/boundary_lint.exs [--consumer [<каталог> ...]]")
    System.halt(2)
  end

  defp check(mode, dirs, rules) do
    errors = Enum.flat_map(dirs, &check_dir(&1, mode))

    if errors == [] do
      IO.puts("boundary-check (#{mode}): #{Enum.join(dirs, ", ")} — нарушений нет")
    else
      abort(errors, rules)
    end
  end

  defp abort(errors, rules) do
    Enum.each(errors, &IO.puts(:stderr, &1))
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
    |> Enum.flat_map(&check_file(&1, mode))
  end

  # Потребитель держит DI и в тестах (`19-testing.md`), библиотека — только в `lib/*.ex`.
  defp sources(:library), do: "**/*.ex"
  defp sources(:consumer), do: "**/*.{ex,exs}"

  defp check_file(path, mode) do
    {_ast, errors} =
      path
      |> File.read!()
      |> Code.string_to_quoted!()
      |> Macro.prewalk([], fn node, acc -> {node, acc ++ violations(node, path, mode)} end)

    errors
  end

  # ===== библиотека: `Core` не знает потребителя =====

  # Сборочный контекст потребителя: у библиотеки его нет.
  defp violations({:__aliases__, meta, [:Mix, :Project]}, path, :library) do
    [err(path, meta, "`Mix.Project` — сборочный контекст потребителя")]
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
      else: [err(path, meta, "`Application.#{fun}` читает #{inspect(app)} — чужой app-env")]
  end

  # Имя приложения-потребителя приходит переменной, поэтому правило выше его не видит:
  # единственный источник этого имени — `Core.Config.otp_app/0`, и звать его вправе
  # только сам `Core.Config`.
  defp violations({{:., _, [{:__aliases__, _, mods}, :otp_app]}, meta, []}, path, :library) do
    if List.last(mods) == :Config and path != @config,
      do: [err(path, meta, "`otp_app/0` вне `#{@config}`: app-env потребителя читается там")],
      else: []
  end

  # ===== потребитель: DI репозиториев — через `Core.Config.repo!/1` =====

  # Ключ-модуль в `compile_env` — это связывание «behaviour → реализация» руками.
  defp violations(
         {{:., _, [{:__aliases__, _, [:Application]}, fun]}, meta,
          [_app, {:__aliases__, _, _} = key | _]},
         path,
         :consumer
       )
       when fun in @compile_env_funs do
    [
      err(
        path,
        meta,
        "`Application.#{fun}` на #{Macro.to_string(key)}: " <>
          "реализация резолвится `Core.Config.repo!/1`"
      )
    ]
  end

  defp violations(_node, _path, _mode), do: []

  defp err(path, meta, message), do: "#{path}:#{Keyword.get(meta, :line, 0)}: #{message}"
end

BoundaryLint.run(System.argv())
