# Храповик предупреждений фикстуры-потребителя (прототип P3).
#
# Запуск из каталога фикстуры:
#
#     mix run --no-start --no-compile ../ratchet/check_warnings.exs          # сверка с маркерами
#     mix run --no-start --no-compile ../ratchet/check_warnings.exs --dump   # эталон строками
#
# Предупреждения берутся из диагностик Mix (`Mix.Task.run("compile", ["--force"])`), а не из текста
# вывода. Ожидание — маркер в исходнике фикстуры:
#
#     # expect: incompatible types given to Blind.Account.execute/2
#     def a1(...), do: Account.execute(state, cmd)
#
# Маркер отдельной строкой относится к ближайшей следующей строке кода (маркеры копятся), маркер в
# хвосте строки — к своей строке. Совпадение: тот же файл, та же строка, первая строка сообщения
# содержит текст маркера. Каждый маркер съедает одно предупреждение.

defmodule Ratchet do
  @marker ~r/^\s*#\s*expect:\s*(.+?)\s*$/
  @trailing ~r/^(.*\S)\s+#\s*expect:\s*(.+?)\s*$/

  def main(args) do
    root = File.cwd!()
    warnings = warnings(root)

    case args do
      ["--dump"] ->
        Enum.each(warnings, &IO.puts("#{&1.file}:#{&1.line}: #{&1.title} [#{&1.mfa}]"))

      [] ->
        markers = root |> Path.join("lib/**/*.ex") |> Path.wildcard() |> Enum.flat_map(&markers(&1, root))
        report(match(markers, warnings, []), length(markers))
    end
  end

  defp warnings(root) do
    # `mix run --no-compile` грузит пути зависимостей без сборки: изменённый core (path-зависимость)
    # остался бы старым. Повтор `deps.loadpaths` без флагов пересобирает устаревшие зависимости.
    Mix.Task.rerun("deps.loadpaths", [])
    {_status, diagnostics} = Mix.Task.run("compile", ["--force", "--return-errors"])

    diagnostics
    |> Enum.filter(&(&1.severity == :warning))
    |> Enum.map(fn diagnostic ->
      %{
        file: Path.relative_to(diagnostic.file, root),
        line: line(diagnostic.position),
        title: diagnostic.message |> String.split("\n", parts: 2) |> hd() |> String.trim(),
        mfa: mfa(diagnostic.stacktrace)
      }
    end)
    |> Enum.sort()
  end

  defp line({line, _column}), do: line
  defp line(line) when is_integer(line), do: line

  defp mfa([{mod, fun, arity, _} | _]), do: Exception.format_mfa(mod, fun, arity)
  defp mfa(_), do: "-"

  defp markers(path, root) do
    file = Path.relative_to(path, root)

    {markers, _pending} =
      path
      |> File.read!()
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.reduce({[], []}, fn {text, line}, {acc, pending} ->
        cond do
          match = Regex.run(@marker, text) ->
            {acc, [Enum.at(match, 1) | pending]}

          String.trim(text) == "" or String.starts_with?(String.trim(text), "#") ->
            {acc, pending}

          match = Regex.run(@trailing, text) ->
            own = %{file: file, line: line, text: Enum.at(match, 2)}
            {[own | assign(pending, file, line) ++ acc], []}

          true ->
            {assign(pending, file, line) ++ acc, []}
        end
      end)

    Enum.reverse(markers)
  end

  defp assign(pending, file, line), do: Enum.map(pending, &%{file: file, line: line, text: &1})

  defp match([], warnings, missing), do: {Enum.reverse(missing), warnings}

  defp match([marker | markers], warnings, missing) do
    index =
      Enum.find_index(warnings, fn warning ->
        warning.file == marker.file and warning.line == marker.line and
          String.contains?(warning.title, marker.text)
      end)

    case index do
      nil -> match(markers, warnings, [marker | missing])
      index -> match(markers, List.delete_at(warnings, index), missing)
    end
  end

  defp report({[], []}, count) do
    IO.puts("ratchet: ok — #{count} ожидаемых предупреждений, лишних нет")
  end

  defp report({missing, extra}, count) do
    IO.puts("ratchet: FAIL — маркеров #{count}, пропало #{length(missing)}, лишних #{length(extra)}")

    Enum.each(missing, fn marker ->
      IO.puts("  пропало: #{marker.file}:#{marker.line}: #{marker.text}")
    end)

    Enum.each(extra, fn warning ->
      IO.puts("  лишнее:  #{warning.file}:#{warning.line}: #{warning.title} [#{warning.mfa}]")
    end)

    System.halt(1)
  end
end

Ratchet.main(System.argv())
