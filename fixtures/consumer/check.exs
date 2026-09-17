# Храповик вывода типов: предупреждения компилятора фикстуры против маркеров в её исходниках.
#
# Запуск из каталога фикстуры (так зовёт `make consumer-check`):
#
#     mix run --no-start --no-compile check.exs          # сверка
#     mix run --no-start --no-compile check.exs --dump   # предупреждения: file:line: заголовок [функция]
#
# Предупреждения — диагностики компиляции через Mix API, а не разбор текста вывода. Ожидание — маркер
# отдельной строкой над ошибочной строкой:
#
#     # expect: incompatible types given to Consumer.Account.execute/2
#     def a3(%Order{} = state, %Account.Cmd.Open{} = command), do: Account.execute(state, command)
#
# Маркер относится к ближайшей следующей строке кода; несколько маркеров подряд — к одной строке.
# Совпадение: тот же файл, та же строка, первая строка сообщения начинается с текста маркера. Маркер
# съедает одно предупреждение. Ожидание без предупреждения и предупреждение без ожидания — провал,
# код выхода 1.

defmodule ConsumerCheck do
  @moduledoc false

  @marker ~r/^\s*#\s*expect:\s*(.+?)\s*$/

  def main(["--dump"]) do
    File.cwd!()
    |> compile_warnings()
    |> Enum.each(&IO.puts(format(&1)))
  end

  def main([]) do
    root = File.cwd!()
    warnings = compile_warnings(root)

    markers =
      root
      |> Path.join("lib/**/*.ex")
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.flat_map(&markers(&1, root))

    report(reconcile(markers, warnings, []), length(markers))
  end

  def main(_args) do
    IO.puts(:stderr, "использование: mix run --no-start --no-compile check.exs [--dump]")
    System.halt(2)
  end

  # ---

  # Пересобирает фикстуру и отдаёт её предупреждения; ошибка компиляции — выход с кодом 1.
  defp compile_warnings(root) do
    # `mix run --no-compile` грузит пути зависимостей без сборки, и изменённый core (path-зависимость)
    # остался бы прежним: повтор `deps.loadpaths` пересобирает устаревшие зависимости.
    Mix.Task.rerun("deps.loadpaths", [])

    diagnostics =
      case quietly(fn -> Mix.Task.run("compile", ["--force", "--return-errors"]) end) do
        {:error, diagnostics} -> halt_on_errors(diagnostics, root)
        {_status, diagnostics} -> diagnostics
      end

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

  # Компилятор печатает каждое из десятков ожидаемых предупреждений в stderr; вывод шага — только
  # итог сверки. Ошибки компиляции печатает `halt_on_errors/2`.
  defp quietly(fun) do
    {:ok, device} = StringIO.open("")
    original = Process.whereis(:standard_error)
    register_standard_error(device)

    try do
      fun.()
    after
      register_standard_error(original)
      StringIO.close(device)
    end
  end

  defp register_standard_error(pid) do
    Process.unregister(:standard_error)
    true = Process.register(pid, :standard_error)
  end

  defp halt_on_errors(diagnostics, root) do
    diagnostics
    |> Enum.filter(&(&1.severity == :error))
    |> Enum.each(fn diagnostic ->
      location = "#{Path.relative_to(diagnostic.file, root)}:#{line(diagnostic.position)}"
      IO.puts(:stderr, "#{location}: #{diagnostic.message}")
    end)

    IO.puts(:stderr, "\nconsumer-check: фикстура не собирается")
    System.halt(1)
  end

  defp line(line) when is_integer(line), do: line
  defp line({line, _column}), do: line
  defp line({line, _column, _end_line, _end_column}), do: line
  defp line(nil), do: 0

  defp mfa([{mod, fun, arity, _location} | _]), do: Exception.format_mfa(mod, fun, arity)
  defp mfa(_stacktrace), do: "-"

  defp markers(path, root) do
    file = Path.relative_to(path, root)

    {markers, _pending} =
      path
      |> File.read!()
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.reduce({[], []}, fn {text, line}, {acc, pending} ->
        trimmed = String.trim(text)

        cond do
          match = Regex.run(@marker, text) -> {acc, [Enum.at(match, 1) | pending]}
          trimmed == "" or String.starts_with?(trimmed, "#") -> {acc, pending}
          true -> {Enum.map(pending, &%{file: file, line: line, text: &1}) ++ acc, []}
        end
      end)

    Enum.reverse(markers)
  end

  # Маркеры без предупреждения и предупреждения без маркера: `{missing, extra}`.
  defp reconcile([], warnings, missing), do: {Enum.reverse(missing), warnings}

  defp reconcile([marker | markers], warnings, missing) do
    index =
      Enum.find_index(warnings, fn warning ->
        warning.file == marker.file and warning.line == marker.line and
          String.starts_with?(warning.title, marker.text)
      end)

    case index do
      nil -> reconcile(markers, warnings, [marker | missing])
      index -> reconcile(markers, List.delete_at(warnings, index), missing)
    end
  end

  defp report({[], []}, count) do
    IO.puts("consumer-check: ok — ожидаемых предупреждений #{count}, лишних нет")
  end

  defp report({missing, extra}, count) do
    Enum.each(missing, &IO.puts(:stderr, "нет предупреждения: #{&1.file}:#{&1.line}: #{&1.text}"))
    Enum.each(extra, &IO.puts(:stderr, "лишнее: #{format(&1)}"))

    IO.puts(
      :stderr,
      "\nconsumer-check: FAIL — маркеров #{count}, без предупреждения #{length(missing)}, " <>
        "лишних предупреждений #{length(extra)}; маркер — fixtures/consumer/README.md"
    )

    System.halt(1)
  end

  defp format(warning), do: "#{warning.file}:#{warning.line}: #{warning.title} [#{warning.mfa}]"
end

ConsumerCheck.main(System.argv())
