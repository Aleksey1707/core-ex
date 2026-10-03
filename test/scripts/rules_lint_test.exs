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

  defp consumer(dir, index) do
    write(dir, "docs/rules/00-index.md", index)
    write(dir, "AGENTS.md", "# Агенты\n")
    File.rm(Path.join(dir, "CLAUDE.md"))
    File.ln_s("AGENTS.md", Path.join(dir, "CLAUDE.md"))
    File.mkdir_p!(Path.join(dir, "deps"))
    File.rm(Path.join(dir, "deps/core"))
    File.ln_s(@root, Path.join(dir, "deps/core"))
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
