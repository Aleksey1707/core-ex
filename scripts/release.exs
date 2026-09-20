# Выпуск: сводит версию в трёх местах разом — `mix.exs` (`@version`), `README.md`
# (`tag:` в примере подключения) и верхний раздел `CHANGELOG.md` («Не выпущено» → `## X.Y.Z`).
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

  @mix_re ~r/@version "(\d+\.\d+\.\d+)"/
  @readme_re ~r/tag: "v(\d+\.\d+\.\d+)"/
  @heading_re ~r/^## (.+)$/m
  @version_re ~r/^\d+\.\d+\.\d+$/

  def run([version]), do: release(version, current())

  def run(_args), do: abort("аргумент — версия выпуска: elixir scripts/release.exs X.Y.Z")

  # ---

  defp release(version, current) do
    ensure_format!(version)
    ensure_ahead!(version, current)
    ensure_unreleased!()

    replace!(@mix, @mix_re, ~s(@version "#{version}"))
    replace!(@readme, @readme_re, ~s(tag: "v#{version}"))
    replace!(@changelog, @heading_re, "## #{version}")

    report(version, current)
  end

  defp ensure_format!(version) do
    unless Regex.match?(@version_re, version) do
      abort("версия выпуска — X.Y.Z, получено #{inspect(version)}")
    end
  end

  defp ensure_ahead!(version, current) do
    unless Version.compare(version, current) == :gt do
      abort("версия #{version} не больше текущей #{current} в #{@mix}")
    end
  end

  defp ensure_unreleased!() do
    case capture!(@heading_re, @changelog) do
      @unreleased ->
        :ok

      heading ->
        abort("#{@changelog}: верхний раздел — «#{heading}», а не «#{@unreleased}»: выпускать нечего")
    end
  end

  defp report(version, current) do
    IO.puts("release: #{current} → #{version}")
    IO.puts("  #{@mix}, #{@readme}, #{@changelog} сведены\n")
    IO.puts("дальше:")
    IO.puts("  git add #{@mix} #{@readme} #{@changelog} && git commit -m \"version up\"")
    IO.puts("  git tag v#{version} && git push origin HEAD v#{version}")
  end

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
