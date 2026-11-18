# Выпуск: финальный выпуск сводит версию в трёх местах разом — `mix.exs` (`@version`),
# `README.md` (`tag:` в примере подключения) и верхний раздел `CHANGELOG.md`
# («Не выпущено» → `## X.Y.Z`). Пререлиз (`X.Y.Z-rc.N` или другой semver-суффикс) сводит только
# `mix.exs` и `README.md`: «Не выпущено» остаётся до финального выпуска, который идёт обычным путём.
# Запуск: elixir scripts/release.exs X.Y.Z (цель `make release VERSION=X.Y.Z`).
#
# Коммит и тег — за оператором: скрипт печатает их команды. Сведение проверяет
# `scripts/release_lint.exs` (`make release-check`, хук `pre-push`).

defmodule Release do
  @moduledoc false

  @mix "mix.exs"
  @readme "README.md"
  @changelog "CHANGELOG.md"
  @unreleased "Не выпущено"

  @mix_re ~r/@version "([^"]+)"/
  @readme_re ~r/tag: "v([^"]+)"/
  @heading_re ~r/^## (.+)$/m

  @spec run([String.t()]) :: :ok

  def run([version]), do: release(version, current())

  def run(_args), do: abort("аргумент — версия выпуска: elixir scripts/release.exs X.Y.Z")

  # ---

  defp release(version, current) do
    ensure_format!(version)
    ensure_ahead!(version, current)
    ensure_unreleased!()

    files = touched(version)
    replace!(@mix, @mix_re, ~s(@version "#{version}"))
    replace!(@readme, @readme_re, ~s(tag: "v#{version}"))
    if final?(version), do: replace!(@changelog, @heading_re, "## #{version}")

    report(version, current, files)
  end

  defp ensure_format!(version) do
    unless valid_version?(version) do
      abort("версия выпуска — X.Y.Z или X.Y.Z-пререлиз, получено #{inspect(version)}")
    end
  end

  defp ensure_ahead!(version, current) do
    unless Version.compare(version, current) == :gt do
      abort("версия #{version} не больше текущей #{current} в #{@mix}")
    end
  end

  defp ensure_unreleased! do
    case capture!(@heading_re, @changelog) do
      @unreleased ->
        :ok

      heading ->
        abort("#{@changelog}: верхний раздел — «#{heading}», а не «#{@unreleased}»: выпускать нечего")
    end
  end

  defp report(version, current, files) do
    IO.puts("release: #{current} → #{version}")
    IO.puts("  #{Enum.join(files, ", ")} сведены\n")
    IO.puts("дальше:")
    IO.puts("  git add #{Enum.join(files, " ")} && git commit -m \"version up\"")
    IO.puts("  git tag v#{version} && git push origin HEAD v#{version}")
  end

  defp touched(version), do: [@mix, @readme] ++ if(final?(version), do: [@changelog], else: [])

  defp final?(version), do: match?({:ok, %Version{pre: []}}, Version.parse(version))

  defp valid_version?(version), do: match?({:ok, %Version{build: nil}}, Version.parse(version))

  defp current, do: capture!(@mix_re, @mix)

  defp replace!(path, regex, replacement) do
    content = File.read!(path)
    File.write!(path, String.replace(content, regex, replacement, global: false))
  end

  defp capture!(regex, path) do
    case Regex.run(regex, File.read!(path)) do
      [_match, value] -> String.trim(value)
      nil -> abort("#{path}: версия не найдена по #{inspect(regex)}")
    end
  end

  defp abort(message) do
    IO.puts(:stderr, "release: #{message}")
    System.halt(1)
  end
end

Release.run(System.argv())
