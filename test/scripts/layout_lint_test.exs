defmodule LayoutLintTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  @script Path.expand("../../scripts/layout_lint.exs", __DIR__)

  test "переменная `quote` — не форма `quote`", %{tmp_dir: dir} do
    write(dir, "lib/a.ex", """
    defmodule A do
      def total(quote), do: amount(quote)

      # ---

      defp amount(quote), do: quote.amount
    end
    """)

    assert {out, 0} = lint(dir)
    assert out =~ "нарушений нет"
  end

  defp write(dir, path, source) do
    path = Path.join(dir, path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, source)
  end

  defp lint(dir), do: System.cmd("elixir", [@script], cd: dir, env: bare_env(), stderr_to_stdout: true)

  defp bare_env do
    for {name, _value} <- System.get_env(), name not in ~w(PATH HOME LANG LC_ALL LC_CTYPE), into: %{}, do: {name, nil}
  end
end
