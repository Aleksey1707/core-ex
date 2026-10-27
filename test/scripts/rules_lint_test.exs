defmodule RulesLintTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  @script Path.expand("../../scripts/rules_lint.exs", __DIR__)
  @root Path.expand("../..", __DIR__)

  describe "--consumer: строка «Первый релиз» локального индекса" do
    test "строки нет — нарушение со ссылкой на норму", %{tmp_dir: dir} do
      consumer(dir, "# Свод\n")

      assert {out, 1} = lint(dir)
      assert out =~ "docs/rules/00-index.md:1: нет строки «Первый релиз: …»"
    end

    test "обе формы приняты", %{tmp_dir: dir} do
      for line <- ["Первый релиз: не состоялся", "Первый релиз: 2026-11-02, 0.1.0"] do
        consumer(dir, "# Свод\n\n#{line}\n")

        {out, _code} = lint(dir)
        refute out =~ "Первый релиз"
      end
    end

    test "строка не по форме — нарушение с номером строки", %{tmp_dir: dir} do
      consumer(dir, "# Свод\n\nПервый релиз: в ноябре\n")

      assert {out, 1} = lint(dir)
      assert out =~ "docs/rules/00-index.md:3: строка «Первый релиз» не по форме"
    end

    test "строки внутри блока кода не считаются: пример формы из нормы", %{tmp_dir: dir} do
      consumer(dir, """
      Первый релиз: не состоялся

      ```markdown
      Первый релиз: не состоялся
      Первый релиз: 2026-11-02, 0.1.0
      ```
      """)

      {out, _code} = lint(dir)
      refute out =~ "Первый релиз"
    end

    test "строка в разметке — не по форме, а не «нет строки»", %{tmp_dir: dir} do
      consumer(dir, "# Свод\n\n**Первый релиз:** не состоялся\n")

      assert {out, 1} = lint(dir)
      assert out =~ "docs/rules/00-index.md:3: строка «Первый релиз» не по форме"
      refute out =~ "нет строки"
    end

    test "две строки — нарушение", %{tmp_dir: dir} do
      consumer(dir, "Первый релиз: не состоялся\nПервый релиз: 2026-11-02, 0.1.0\n")

      assert {out, 1} = lint(dir)
      assert out =~ "docs/rules/00-index.md:2: вторая строка «Первый релиз»"
    end
  end

  describe "библиотека: проговорённое отсутствие проверки" do
    test "фраза об отсутствии проверки в обоих ярусах — нарушение с номером строки", %{tmp_dir: dir} do
      library(dir)
      append(dir, "docs/rules/13-repos.md", "Опечатку в ключе сборка не ловит.")
      append(dir, "docs/rules/12-errors.md", "Сборка этого не ловит.")
      append(dir, "docs/rules/19-testing.md", "Доступ — `KeyError`, сборка его не ловит.")
      append(dir, "docs/rules/app/19-testing.md", "Раскладку линтер дерево `test/` не проверяет.")

      assert {out, 1} = lint_library(dir)
      assert out =~ ~r/docs\/rules\/13-repos\.md:\d+: отсутствие проверки проговорено: «сборка не ловит»/
      assert out =~ ~r/docs\/rules\/12-errors\.md:\d+: отсутствие проверки проговорено: «Сборка этого не ловит»/
      assert out =~ ~r/docs\/rules\/19-testing\.md:\d+: отсутствие проверки проговорено: «сборка его не ловит»/
      assert out =~ ~r/docs\/rules\/app\/19-testing\.md:\d+: отсутствие проверки проговорено: «линтер/
    end

    test "поведение кода и пример в блоке кода — без нарушений", %{tmp_dir: dir} do
      library(dir)

      append(dir, "docs/rules/13-repos.md", """
      `page_stream` доступ не проверяет, а round-trip не ловит сдвиг нумерации.

      ```elixir
      # плохо — сборка не ловит
      ```
      """)

      assert {out, 0} = lint_library(dir)
      refute out =~ "отсутствие проверки"
    end
  end

  defp library(dir) do
    for path <- ~w(docs/rules .claude/skills AGENTS.md) do
      File.mkdir_p!(Path.dirname(Path.join(dir, path)))
      File.cp_r!(Path.join(@root, path), Path.join(dir, path))
    end

    File.ln_s!("AGENTS.md", Path.join(dir, "CLAUDE.md"))
  end

  defp append(dir, path, text) do
    full = Path.join(dir, path)
    [head, tail] = String.split(File.read!(full), "\n## Связанные правила", parts: 2)
    File.write!(full, head <> "\n" <> text <> "\n\n## Связанные правила" <> tail)
  end

  defp lint_library(dir), do: System.cmd("elixir", [@script], cd: dir, env: bare_env(), stderr_to_stdout: true)

  defp consumer(dir, index) do
    write(dir, "docs/rules/00-index.md", index)
    write(dir, "AGENTS.md", "# Агенты\n")
    File.rm(Path.join(dir, "CLAUDE.md"))
    File.ln_s("AGENTS.md", Path.join(dir, "CLAUDE.md"))
    File.mkdir_p!(Path.join(dir, "deps"))
    link = Path.join(dir, "deps/core")
    File.rm(link)
    File.ln_s(@root, link)
    on_exit(fn -> File.rm(link) end)
  end

  defp write(dir, path, content) do
    full = Path.join(dir, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, content)
  end

  defp lint(dir), do: System.cmd("elixir", [@script, "--consumer"], cd: dir, env: bare_env(), stderr_to_stdout: true)

  defp bare_env do
    for {name, _value} <- System.get_env(), name not in ~w(PATH HOME LANG LC_ALL LC_CTYPE), into: %{}, do: {name, nil}
  end
end
