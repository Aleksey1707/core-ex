# Сведение версии выпуска: `mix.exs` (`@version`), `README.md` (`tag: "vX.Y.Z"` в примере
# подключения) и верхний заголовок `CHANGELOG.md` называют одну версию, а тег `vX.Y.Z` на
# коммите — её же. Запуск: elixir scripts/release_lint.exs (цель `make release-check`, хук
# `pre-push`).
#
# Пока выпуска нет, верхний заголовок CHANGELOG — «Не выпущено», а `mix.exs` и `README.md`
# называют прошлый выпуск: это штатное состояние ветки, и оно нарушением не считается. Тег на
# таком коммите — нарушение: под ним уедет версия прошлого выпуска. Проверка читает файлы из
# коммита тега (`git show`), а без тега — из рабочего дерева.

defmodule ReleaseLint do
  @moduledoc false

  @mix "mix.exs"
  @readme "README.md"
  @changelog "CHANGELOG.md"
  @unreleased "Не выпущено"

  @mix_re ~r/@version "(\d+\.\d+\.\d+)"/
  @readme_re ~r/tag: "v(\d+\.\d+\.\d+)"/
  @heading_re ~r/^## (.+)$/m
  @tag_re ~r/^v(\d+\.\d+\.\d+)$/

  def run do
    tag = head_tag()
    ref = if tag, do: "v#{tag}", else: nil

    versions = %{
      mix: capture!(@mix_re, read!(ref, @mix), @mix),
      readme: capture!(@readme_re, read!(ref, @readme), @readme),
      changelog: capture!(@heading_re, read!(ref, @changelog), @changelog)
    }

    case errors(tag, versions) do
      [] -> IO.puts(report(tag, versions))
      errors -> abort(errors)
    end
  end

  # ---

  defp errors(tag, versions) do
    List.flatten([
      readme_error(versions),
      changelog_error(versions),
      tag_errors(tag, versions)
    ])
  end

  defp readme_error(%{mix: mix, readme: readme}) when mix != readme do
    ["#{@readme}: пример подключения — тег v#{readme}, а #{@mix} — версия #{mix}"]
  end

  defp readme_error(_versions), do: []

  defp changelog_error(%{changelog: @unreleased}), do: []

  defp changelog_error(%{mix: mix, changelog: changelog}) when mix != changelog do
    ["#{@changelog}: верхний раздел — «#{changelog}», а #{@mix} — версия #{mix}"]
  end

  defp changelog_error(_versions), do: []

  defp tag_errors(nil, _versions), do: []

  defp tag_errors(tag, %{mix: mix, changelog: changelog}) do
    [
      if(tag != mix, do: "тег v#{tag} стоит на коммите с версией #{mix} в #{@mix}", else: []),
      if(changelog == @unreleased,
        do: "тег v#{tag} стоит на коммите с разделом «#{@unreleased}» в #{@changelog}",
        else: []
      )
    ]
  end

  defp report(nil, %{mix: mix, changelog: @unreleased}),
    do: "release-check: не выпущено, последний выпуск — #{mix}"

  defp report(nil, %{mix: mix}), do: "release-check: версия сведена — #{mix}"
  defp report(tag, _versions), do: "release-check: тег v#{tag} сведён"

  defp head_tag do
    case System.cmd("git", ["tag", "--points-at", "HEAD"], stderr_to_stdout: true) do
      {out, 0} -> out |> String.split("\n", trim: true) |> Enum.find_value(&version_of/1)
      {_out, _code} -> nil
    end
  end

  defp version_of(tag) do
    case Regex.run(@tag_re, String.trim(tag)) do
      [_match, version] -> version
      nil -> nil
    end
  end

  defp read!(nil, path), do: File.read!(path)

  defp read!(ref, path) do
    case System.cmd("git", ["show", "#{ref}:#{path}"], stderr_to_stdout: true) do
      {content, 0} -> content
      {out, _code} -> abort(["git show #{ref}:#{path}: #{String.trim(out)}"])
    end
  end

  defp capture!(regex, content, path) do
    case Regex.run(regex, content) do
      [_match, value] -> String.trim(value)
      nil -> abort(["#{path}: версия не найдена по #{inspect(regex)}"])
    end
  end

  defp abort(errors) do
    Enum.each(errors, &IO.puts(:stderr, &1))

    IO.puts(:stderr, "\nrelease-check: нарушений — #{length(errors)}; выпуск — make release VERSION=X.Y.Z")
    System.halt(1)
  end
end

ReleaseLint.run()
