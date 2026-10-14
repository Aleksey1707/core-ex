# Форма результата в типах: `@spec` / `@callback` / `@type` пишут результат через `Core.Result`, а не
# прописью — `docs/rules/20-agreements.md`, «Форма результата». Проверка идёт по AST.
# Запуск: elixir scripts/spec_lint.exs  (цель `make spec-check`); у потребителя —
# elixir deps/core/scripts/spec_lint.exs, и путь правил в сообщениях — `deps/core/…`.
#
# Нарушение — объединение ровно из успехов (`{:ok, a}` либо `:ok`) и ошибок (`{:error, e}`), а также
# `Result.t` / `Result.unit` с параметром, который совпадает с умолчанием, и короткое `Result` внутри
# `quote`. Объединение с третьим вариантом (`{:skip, _}`) или unit вместе с valued — исключение
# нормы, его линтер не трогает.

defmodule SpecLint do
  @moduledoc false

  @rules "docs/rules/20-agreements.md"
  @dep_rules_dir "deps/core/docs/rules"
  @paths ["lib/**/*.{ex,exs}", "test/support/**/*.{ex,exs}"]

  @attrs ~w(spec callback macrocallback type typep opaque)a
  @result [[:Result], [:Core, :Result]]
  @error [[:Error], [:Core, :Error]]

  def run do
    files = @paths |> Enum.flat_map(&Path.wildcard/1) |> Enum.uniq() |> Enum.sort()
    errors = Enum.flat_map(files, &check_file/1)

    case errors do
      [] -> IO.puts("spec-check: #{length(files)} файлов, нарушений нет")
      errors -> abort(errors)
    end
  end

  # ---

  defp abort(errors) do
    errors
    |> Enum.sort_by(fn {path, line, _} -> {path, line} end)
    |> Enum.each(fn {path, line, message} -> IO.puts(:stderr, "#{path}:#{line}: #{message}") end)

    IO.puts(:stderr, "\nspec-check: нарушений — #{length(errors)}; правила — #{rules()}")
    System.halt(1)
  end

  # У потребителя свод приехал зависимостью: его `docs/rules/` — уже локальный свод.
  defp rules do
    if File.dir?(@dep_rules_dir),
      do: Path.join("deps/core", @rules),
      else: @rules
  end

  defp check_file(path) do
    ast = path |> File.read!() |> Code.string_to_quoted!(columns: true)
    walk(ast, %{path: path, quoted?: false, line: nil, short?: short_result?(ast)}, [])
  end

  # Короткое `Result` — это `Core.Result`, пока файл не алиасит под этим именем другой модуль
  # (`alias Core.Pagination.Result`).
  defp short_result?(ast) do
    {_ast, other?} =
      Macro.prewalk(ast, false, fn
        {:alias, _, [{:__aliases__, _, mod} | opts]} = node, acc -> {node, acc or other_result?(mod, opts)}
        node, acc -> {node, acc}
      end)

    not other?
  end

  defp other_result?(mod, [[as: {:__aliases__, _, [:Result]}]]), do: mod != [:Core, :Result]
  defp other_result?(mod, []), do: List.last(mod) == :Result and mod != [:Core, :Result]
  defp other_result?(_mod, _opts), do: false

  # `Core.Result` сам заводит имена форм: его `@type t` / `@type unit` и есть пропись.
  defp walk({:defmodule, _meta, [{:__aliases__, _, [:Core, :Result]} | _]}, _ctx, acc), do: acc

  defp walk({:quote, _meta, args}, ctx, acc), do: walk(args, %{ctx | quoted?: true}, acc)

  defp walk({:@, meta, [{attr, _, [type]}]}, ctx, acc) when attr in @attrs,
    do: check_type(type, %{ctx | line: meta[:line]}, acc)

  defp walk(node, ctx, acc), do: node |> children() |> Enum.reduce(acc, &walk(&1, ctx, &2))

  # Объединение разбирается целиком на верхнем `|`, затем — его члены: пропись бывает вложена
  # в тип аргумента или колбэка.
  defp check_type({:|, _, _} = union, ctx, acc) do
    members = flatten(union)
    Enum.reduce(members, prose_error(members, ctx) ++ acc, &check_type(&1, ctx, &2))
  end

  defp check_type(type, ctx, acc),
    do: type |> children() |> Enum.reduce(name_error(type, ctx) ++ acc, &check_type(&1, ctx, &2))

  defp children({form, _meta, args}) when is_list(args), do: [form | args]
  defp children({left, right}), do: [left, right]
  defp children(list) when is_list(list), do: list
  defp children(_leaf), do: []

  defp flatten({:|, _, [left, right]}), do: flatten(left) ++ flatten(right)
  defp flatten(type), do: [type]

  # Нарушение — объединение ровно из успехов одного рода и ошибок: `:ok` вместе с `{:ok, _}` —
  # исключение нормы (unit с valued).
  defp prose_error(members, ctx) do
    {oks, rest} = Enum.split_with(members, &ok?/1)
    {errors, other} = Enum.split_with(rest, &match?({:error, _}, &1))

    case {oks, errors, other} do
      {[:ok], [_ | _], []} -> [prose(:unit, [reasons(errors)], ctx)]
      {[_ | _], [_ | _], []} -> if :ok in oks, do: [], else: [prose(:t, [values(oks), reasons(errors)], ctx)]
      _other -> []
    end
  end

  defp ok?(:ok), do: true
  defp ok?({:ok, _value}), do: true
  defp ok?(_type), do: false

  defp values(oks), do: oks |> Enum.map(fn {:ok, value} -> value end) |> union()
  defp reasons(errors), do: errors |> Enum.map(fn {:error, reason} -> reason end) |> union()

  defp union(types), do: Enum.reduce(types, fn type, union -> {:|, [], [union, type]} end)

  defp prose(name, args, ctx),
    do: err(ctx, "результат прописью — `#{call(prefix(ctx), name, shorten(name, args))}`")

  # Генерируемый код пишет модули полным путём: короткое имя внутри `quote` — нарушение, и
  # подсказка там — с полным путём.
  defp prefix(%{quoted?: true}), do: [:Core, :Result]
  defp prefix(_ctx), do: [:Result]

  defp name_error({{:., _, [{:__aliases__, _, mod}, name]}, _meta, args}, ctx)
       when mod in @result and name in [:t, :unit] do
    shortest = shorten(name, args)

    cond do
      mod == [:Result] and not ctx.short? -> []
      mod == [:Result] and ctx.quoted? -> [err(ctx, "в `quote` — полный путь `#{call(prefix(ctx), name, shortest)}`")]
      shortest != args -> [err(ctx, "форма длиннее нужной — `#{call(mod, name, shortest)}`")]
      true -> []
    end
  end

  defp name_error(_type, _ctx), do: []

  defp shorten(:t, [value, reason]) do
    cond do
      not error?(reason) -> [value, reason]
      term?(value) -> []
      true -> [value]
    end
  end

  defp shorten(:t, [value]), do: if(term?(value), do: [], else: [value])
  defp shorten(:unit, [reason]), do: if(error?(reason), do: [], else: [reason])
  defp shorten(_name, args), do: args

  defp call(mod, name, args), do: "#{Enum.join(mod, ".")}.#{name}(#{Enum.map_join(args, ", ", &Macro.to_string/1)})"

  defp error?({{:., _, [{:__aliases__, _, mod}, :t]}, _meta, []}), do: mod in @error
  defp error?(_type), do: false

  defp term?({name, _meta, args}) when name in [:term, :any] and args in [[], nil], do: true
  defp term?(_type), do: false

  defp err(ctx, message), do: {ctx.path, ctx.line, message}
end

SpecLint.run()
